// ============================================================================
// TNCWatcher Tray Monitor + Settings
//
// System-tray app that shows the TNCWatcher service status at a glance:
//   green  = service running
//   orange = service paused / starting / stopping
//   red    = service stopped or not installed
// Tooltip shows the latest log activity. Self-drawn toast windows pop up in
// the bottom-right corner (above the tray) on:
//   - service state changes and new [ERROR] lines
//   - successful transfers ("Transfer complete")
//   - machine unreachable ("Machine unreachable") - once per file, no repeats
//   - file locked on a reachable machine ("Waiting to retry") - reminder
//     every few minutes until it clears
// These are custom windows (see ToastForm), NOT NotifyIcon balloon tips,
// because balloons route through the Windows notification system - which is
// turned off on this PC (Settings > System > Notifications), so they never
// appeared. The custom windows show regardless of that setting.
//
// Preview the toasts any time with:  TNCWatcher-Tray.exe --toasttest
//
// LEFT-CLICK the icon (or right-click -> Settings...) to open the Settings
// dialog: watch folder, machine IP, destination, filter, retry/timeout
// settings, and the NAS credential. Settings are written to
// TNCWatcher-Config.json (read by the watcher script at startup); the NAS
// credential is DPAPI-encrypted. "Save & Restart Service" launches the
// elevated helper service\Apply-TrayConfig.ps1 (UAC prompt) which installs
// the credential, repairs the 3-hour restart task, and restarts the service.
//
// Double-click = open the live log window.
//
// Build with service\Build-TrayApp.cmd (uses the C# compiler that ships with
// Windows - no SDK required). The EXE expects to live in the project root
// next to TNCcmd-Watcher.log and TNCWatcher-Console.cmd.
// ============================================================================

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.ServiceProcess;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

static class NativeMethods
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        // Hidden preview mode: shows one sample toast of each kind so the
        // notification appearance/position can be verified without waiting for
        // a real transfer. Run:  TNCWatcher-Tray.exe --toasttest
        if (args.Length > 0 && args[0] == "--toasttest")
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new ToastTestContext());
            return;
        }

        // Render sample toasts to a PNG (for verification) and exit.
        if (args.Length >= 2 && args[0] == "--toastsnap")
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            ToastForm.SaveSamplePng(args[1]);
            return;
        }

        bool createdNew;
        using (Mutex mutex = new Mutex(true, "TNCWatcherTraySingleInstance", out createdNew))
        {
            if (!createdNew) return; // already running
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new TrayContext());
        }
    }
}

// Minimal harness that shows sample toasts (real ToastForm) then exits.
class ToastTestContext : ApplicationContext
{
    public ToastTestContext()
    {
        Color green  = Color.FromArgb(46, 204, 64);
        Color orange = Color.FromArgb(255, 165, 0);
        Color red    = Color.FromArgb(224, 62, 45);

        var samples = new[]
        {
            new object[] { "Transfer complete", "Sent to CNC: Ls Delrin Op2.h", green },
            new object[] { "Waiting to retry", "PartB.h is locked on the controller - still retrying (attempt 3/150). Set the machine to Manual to free it.", orange },
            new object[] { "Machine unreachable", "PartC.h will be sent automatically once the machine is back online.", red },
        };

        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        int margin = 12, y = wa.Bottom - margin;
        for (int i = 0; i < samples.Length; i++)
        {
            ToastForm t = new ToastForm((string)samples[i][0], (string)samples[i][1], (Color)samples[i][2], 25000);
            y -= t.Height;
            t.Left = wa.Right - t.Width - margin;
            t.Top = y;
            y -= 8;
            t.Show();
        }

        // Exit the process a little after the toasts self-dismiss.
        System.Windows.Forms.Timer quit = new System.Windows.Forms.Timer();
        quit.Interval = 28000;
        quit.Tick += delegate { quit.Stop(); Application.Exit(); };
        quit.Start();
    }
}

// ---------------------------------------------------------------------------
// Effective watcher configuration: script defaults overlaid with
// TNCWatcher-Config.json (the file this dialog writes).
// ---------------------------------------------------------------------------
class WatcherConfig
{
    public string MachineIP = "";
    public string DestinationFolder = "";
    public string WatchFolder = "";
    public string FileFilter = "*.*";
    public bool IncludeSubdirectories = true;
    public int MaxRetries = 150;
    public int RetryDelaySeconds = 30;
    public int ConnectionTimeout = 30;
    public int TransferTimeoutSeconds = 600;
    public string ToolTableTransferMode = "Merge";
    public string ToolTableFolder = "ToolTables";
    public bool EnableStlTransfer = true;
    public double FixtureClearanceMM = 1.5;
    public int NcSettleDelaySeconds = 45;
    public bool StlUseSubfolderSidecarCheck = true;
    public bool FixtureCutBelowAttach = true;

    public static string ConfigPath(string baseDir) { return Path.Combine(baseDir, "TNCWatcher-Config.json"); }
    public static string ScriptPath(string baseDir) { return Path.Combine(baseDir, "TNCcmd-FolderWatcher.ps1"); }

    // Absolute path of the tool table folder (inside the watch folder unless an
    // absolute path was configured).
    public string ResolvedToolTableFolder()
    {
        string f = (ToolTableFolder == null || ToolTableFolder.Length == 0) ? "ToolTables" : ToolTableFolder;
        try { if (Path.IsPathRooted(f)) return f; } catch { }
        try { return Path.Combine(WatchFolder, f); } catch { return f; }
    }

    public static WatcherConfig Load(string baseDir)
    {
        WatcherConfig c = new WatcherConfig();
        c.LoadScriptDefaults(ScriptPath(baseDir));
        c.OverlayJson(ConfigPath(baseDir));
        return c;
    }

    void LoadScriptDefaults(string scriptPath)
    {
        try
        {
            if (!File.Exists(scriptPath)) return;
            string text = File.ReadAllText(scriptPath);
            MachineIP              = MatchString(text, "MachineIP", MachineIP);
            DestinationFolder      = MatchString(text, "DestinationFolder", DestinationFolder);
            WatchFolder            = MatchString(text, "WatchFolder", WatchFolder);
            FileFilter             = MatchString(text, "FileFilter", FileFilter);
            IncludeSubdirectories  = MatchBool(text, "IncludeSubdirectories", IncludeSubdirectories);
            MaxRetries             = MatchInt(text, "MaxRetries", MaxRetries);
            RetryDelaySeconds      = MatchInt(text, "RetryDelaySeconds", RetryDelaySeconds);
            ConnectionTimeout      = MatchInt(text, "ConnectionTimeout", ConnectionTimeout);
            TransferTimeoutSeconds = MatchInt(text, "TransferTimeoutSeconds", TransferTimeoutSeconds);
            ToolTableTransferMode  = MatchString(text, "ToolTableTransferMode", ToolTableTransferMode);
            ToolTableFolder        = MatchString(text, "ToolTableFolder", ToolTableFolder);
            EnableStlTransfer      = MatchBool(text, "EnableStlTransfer", EnableStlTransfer);
            FixtureClearanceMM     = MatchDouble(text, "FixtureClearanceMM", FixtureClearanceMM);
            NcSettleDelaySeconds   = MatchInt(text, "NcSettleDelaySeconds", NcSettleDelaySeconds);
            StlUseSubfolderSidecarCheck = MatchBool(text, "StlUseSubfolderSidecarCheck", StlUseSubfolderSidecarCheck);
            FixtureCutBelowAttach  = MatchBool(text, "FixtureCutBelowAttach", FixtureCutBelowAttach);
        }
        catch { }
    }

    static string MatchString(string text, string name, string fallback)
    {
        Match m = Regex.Match(text, @"^\s*\$" + name + "\\s*=\\s*\"([^\"]*)\"", RegexOptions.Multiline);
        return m.Success ? m.Groups[1].Value : fallback;
    }

    static bool MatchBool(string text, string name, bool fallback)
    {
        Match m = Regex.Match(text, @"^\s*\$" + name + @"\s*=\s*\$(true|false)", RegexOptions.Multiline);
        return m.Success ? (m.Groups[1].Value == "true") : fallback;
    }

    static double MatchDouble(string text, string name, double fallback)
    {
        Match m = Regex.Match(text, @"^\s*\$" + name + @"\s*=\s*([0-9]*\.?[0-9]+)", RegexOptions.Multiline);
        double v;
        return (m.Success && double.TryParse(m.Groups[1].Value, System.Globalization.NumberStyles.Float,
                CultureInfo.InvariantCulture, out v)) ? v : fallback;
    }

    static int MatchInt(string text, string name, int fallback)
    {
        Match m = Regex.Match(text, @"^\s*\$" + name + @"\s*=\s*(\d+)", RegexOptions.Multiline);
        int v;
        return (m.Success && int.TryParse(m.Groups[1].Value, out v)) ? v : fallback;
    }

    void OverlayJson(string jsonPath)
    {
        try
        {
            if (!File.Exists(jsonPath)) return;
            JavaScriptSerializer ser = new JavaScriptSerializer();
            Dictionary<string, object> d = ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(jsonPath));
            if (d == null) return;
            object v;
            if (d.TryGetValue("MachineIP", out v) && v != null)              MachineIP = v.ToString();
            if (d.TryGetValue("DestinationFolder", out v) && v != null)      DestinationFolder = v.ToString();
            if (d.TryGetValue("WatchFolder", out v) && v != null)            WatchFolder = v.ToString();
            if (d.TryGetValue("FileFilter", out v) && v != null)             FileFilter = v.ToString();
            if (d.TryGetValue("IncludeSubdirectories", out v) && v is bool)  IncludeSubdirectories = (bool)v;
            if (d.TryGetValue("MaxRetries", out v) && v != null)             MaxRetries = ToInt(v, MaxRetries);
            if (d.TryGetValue("RetryDelaySeconds", out v) && v != null)      RetryDelaySeconds = ToInt(v, RetryDelaySeconds);
            if (d.TryGetValue("ConnectionTimeout", out v) && v != null)      ConnectionTimeout = ToInt(v, ConnectionTimeout);
            if (d.TryGetValue("TransferTimeoutSeconds", out v) && v != null) TransferTimeoutSeconds = ToInt(v, TransferTimeoutSeconds);
            if (d.TryGetValue("ToolTableTransferMode", out v) && v != null)  ToolTableTransferMode = v.ToString();
            if (d.TryGetValue("ToolTableFolder", out v) && v != null)        ToolTableFolder = v.ToString();
            if (d.TryGetValue("EnableStlTransfer", out v) && v is bool)      EnableStlTransfer = (bool)v;
            if (d.TryGetValue("FixtureClearanceMM", out v) && v != null)     FixtureClearanceMM = ToDouble(v, FixtureClearanceMM);
            if (d.TryGetValue("NcSettleDelaySeconds", out v) && v != null)   NcSettleDelaySeconds = ToInt(v, NcSettleDelaySeconds);
            if (d.TryGetValue("StlUseSubfolderSidecarCheck", out v) && v is bool) StlUseSubfolderSidecarCheck = (bool)v;
            if (d.TryGetValue("FixtureCutBelowAttach", out v) && v is bool) FixtureCutBelowAttach = (bool)v;
        }
        catch { }
    }

    static double ToDouble(object v, double fallback)
    {
        double r;
        return double.TryParse(v.ToString(), System.Globalization.NumberStyles.Float,
               CultureInfo.InvariantCulture, out r) ? r : fallback;
    }

    static int ToInt(object v, int fallback)
    {
        int r;
        return int.TryParse(v.ToString(), out r) ? r : fallback;
    }

    public void SaveJson(string baseDir)
    {
        Dictionary<string, object> d = new Dictionary<string, object>();
        d["MachineIP"]              = MachineIP;
        d["DestinationFolder"]      = DestinationFolder;
        d["WatchFolder"]            = WatchFolder;
        d["FileFilter"]             = FileFilter;
        d["IncludeSubdirectories"]  = IncludeSubdirectories;
        d["MaxRetries"]             = MaxRetries;
        d["RetryDelaySeconds"]      = RetryDelaySeconds;
        d["ConnectionTimeout"]      = ConnectionTimeout;
        d["TransferTimeoutSeconds"] = TransferTimeoutSeconds;
        d["ToolTableTransferMode"]  = ToolTableTransferMode;
        d["ToolTableFolder"]        = ToolTableFolder;
        d["EnableStlTransfer"]      = EnableStlTransfer;
        d["FixtureClearanceMM"]     = FixtureClearanceMM;
        d["NcSettleDelaySeconds"]   = NcSettleDelaySeconds;
        d["StlUseSubfolderSidecarCheck"] = StlUseSubfolderSidecarCheck;
        d["FixtureCutBelowAttach"] = FixtureCutBelowAttach;
        JavaScriptSerializer ser = new JavaScriptSerializer();
        File.WriteAllText(ConfigPath(baseDir), ser.Serialize(d));
    }
}

// ---------------------------------------------------------------------------
// Settings dialog
// ---------------------------------------------------------------------------
class SettingsForm : Form
{
    readonly string baseDir;
    TextBox tbIP, tbDest, tbWatch, tbFilter, tbRetries, tbDelay, tbConnTimeout, tbXferTimeout;
    TextBox tbNasUser, tbNasPass;
    CheckBox cbSubdirs;
    ComboBox cbToolMode;
    CheckBox cbStlEnable, cbStlSidecar, cbStlCut;
    TextBox tbClearance, tbSettle;
    string loadedToolTableFolder = "ToolTables"; // preserved across save (no UI field)

    public SettingsForm(string baseDir)
    {
        this.baseDir = baseDir;

        Text = "TNCWatcher Settings";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(520, 768);
        Font = new Font("Segoe UI", 9F);

        int y = 14;
        tbIP     = AddRow("Machine IP:", ref y, null);
        tbDest   = AddRow("CNC destination folder:", ref y, null);
        tbWatch  = AddRow("Watch folder:", ref y, "Browse...");
        tbFilter = AddRow("File filter:", ref y, null);

        cbSubdirs = new CheckBox();
        cbSubdirs.Text = "Watch subfolders too (mirrors folder structure on the CNC)";
        cbSubdirs.SetBounds(178, y, 330, 22);
        Controls.Add(cbSubdirs);
        y += 30;

        tbRetries     = AddRow("Max retries:", ref y, null);
        tbDelay       = AddRow("Retry delay (seconds):", ref y, null);
        tbConnTimeout = AddRow("Command timeout (s):", ref y, null);
        tbXferTimeout = AddRow("Transfer timeout (s):", ref y, null);

        y += 6;
        GroupBox grp = new GroupBox();
        grp.Text = "NAS credential (for the watch folder share)";
        grp.SetBounds(12, y, 496, 96);
        Controls.Add(grp);

        Label lu = new Label(); lu.Text = "NAS username:"; lu.SetBounds(12, 24, 150, 20); grp.Controls.Add(lu);
        tbNasUser = new TextBox(); tbNasUser.SetBounds(166, 22, 200, 23); grp.Controls.Add(tbNasUser);
        Label lp = new Label(); lp.Text = "NAS password:"; lp.SetBounds(12, 52, 150, 20); grp.Controls.Add(lp);
        tbNasPass = new TextBox(); tbNasPass.UseSystemPasswordChar = true; tbNasPass.SetBounds(166, 50, 200, 23); grp.Controls.Add(tbNasPass);
        Label ln = new Label();
        ln.Text = "Leave blank to keep the currently saved credential.";
        ln.ForeColor = Color.DimGray;
        ln.SetBounds(372, 24, 120, 60);
        grp.Controls.Add(ln);
        y += 106;

        // ---- Tool tables ----
        GroupBox ttGrp = new GroupBox();
        ttGrp.Text = "Tool tables";
        ttGrp.SetBounds(12, y, 496, 116);
        Controls.Add(ttGrp);

        Label lm = new Label(); lm.Text = "Transfer mode:"; lm.SetBounds(12, 26, 150, 20); ttGrp.Controls.Add(lm);
        cbToolMode = new ComboBox();
        cbToolMode.DropDownStyle = ComboBoxStyle.DropDownList;
        cbToolMode.Items.AddRange(new object[] { "Merge", "Overwrite" });
        cbToolMode.SetBounds(166, 24, 140, 23);
        ttGrp.Controls.Add(cbToolMode);
        Label lmn = new Label();
        lmn.Text = "Merge needs TNCcmdPlus + Option 18.";
        lmn.ForeColor = Color.DimGray;
        lmn.SetBounds(316, 27, 176, 20);
        ttGrp.Controls.Add(lmn);

        Label lf = new Label();
        lf.Text = "Drop tool tables (e.g. tool.t) in the tool table folder. A backup of the current\nremote table is saved before every send.";
        lf.ForeColor = Color.DimGray;
        lf.SetBounds(12, 52, 472, 32);
        ttGrp.Controls.Add(lf);

        Button btnOpenTT = new Button();
        btnOpenTT.Text = "Open Tool Table Folder";
        btnOpenTT.SetBounds(12, 84, 170, 26);
        btnOpenTT.Click += delegate { OpenToolTableFolder(); };
        ttGrp.Controls.Add(btnOpenTT);

        Button btnSendTT = new Button();
        btnSendTT.Text = "Browse && Send Tool Table…";
        btnSendTT.SetBounds(192, 84, 190, 26);
        btnSendTT.Click += delegate { BrowseAndSendToolTable(); };
        ttGrp.Controls.Add(btnSendTT);
        y += 126;

        // ---- STL / simulation meshes ----
        GroupBox sGrp = new GroupBox();
        sGrp.Text = "Simulation meshes (STL)";
        sGrp.SetBounds(12, y, 496, 158);
        Controls.Add(sGrp);

        cbStlEnable = new CheckBox();
        cbStlEnable.Text = "Send STOCK / PART / FIXTURE meshes with the program";
        cbStlEnable.SetBounds(12, 22, 400, 22);
        sGrp.Controls.Add(cbStlEnable);

        Label lc = new Label(); lc.Text = "Fixture shrink (mm/face):"; lc.SetBounds(12, 52, 150, 20); sGrp.Controls.Add(lc);
        tbClearance = new TextBox(); tbClearance.SetBounds(166, 50, 60, 23); sGrp.Controls.Add(tbClearance);
        Label lch = new Label();
        lch.Text = "each face moves inward this far so DCM does not trip";
        lch.ForeColor = Color.DimGray;
        lch.SetBounds(232, 53, 256, 20);
        sGrp.Controls.Add(lch);

        Label ls = new Label(); ls.Text = "Sidecar grace (s):"; ls.SetBounds(12, 80, 150, 20); sGrp.Controls.Add(ls);
        tbSettle = new TextBox(); tbSettle.SetBounds(166, 78, 60, 23); sGrp.Controls.Add(tbSettle);
        Label lsh = new Label();
        lsh.Text = "extra wait after a program stops growing, for its sidecar";
        lsh.ForeColor = Color.DimGray;
        lsh.SetBounds(232, 81, 256, 20);
        sGrp.Controls.Add(lsh);

        cbStlSidecar = new CheckBox();
        cbStlSidecar.Text = "Detect the post's temp program copy via its subfolder sidecar";
        cbStlSidecar.SetBounds(12, 104, 460, 22);
        sGrp.Controls.Add(cbStlSidecar);

        cbStlCut = new CheckBox();
        cbStlCut.Text = "Cut fixture below the attach point (stops false collisions with the clamp)";
        cbStlCut.SetBounds(12, 128, 470, 22);
        sGrp.Controls.Add(cbStlCut);
        y += 168;

        Label note = new Label();
        note.Text = "\"Save && Restart Service\" applies everything (admin prompt appears).";
        note.ForeColor = Color.DimGray;
        note.SetBounds(12, y, 496, 18);
        Controls.Add(note);
        y += 24;

        Button btnApply = new Button();
        btnApply.Text = "Save && Restart Service";
        btnApply.SetBounds(150, y, 160, 30);
        btnApply.Click += delegate { if (SaveAll()) { LaunchApply(); Close(); } };
        Controls.Add(btnApply);

        Button btnSave = new Button();
        btnSave.Text = "Save Only";
        btnSave.SetBounds(318, y, 90, 30);
        btnSave.Click += delegate
        {
            if (SaveAll())
            {
                MessageBox.Show(this, "Saved. The service picks the changes up on its next restart\n(3-hour auto-restart, reboot, or \"Restart Service\" in the tray menu).",
                    "TNCWatcher", MessageBoxButtons.OK, MessageBoxIcon.Information);
                Close();
            }
        };
        Controls.Add(btnSave);

        Button btnCancel = new Button();
        btnCancel.Text = "Cancel";
        btnCancel.SetBounds(416, y, 90, 30);
        btnCancel.Click += delegate { Close(); };
        Controls.Add(btnCancel);
        CancelButton = btnCancel;

        LoadValues();
    }

    TextBox AddRow(string label, ref int y, string browseText)
    {
        Label l = new Label();
        l.Text = label;
        l.SetBounds(12, y + 3, 160, 20);
        Controls.Add(l);

        TextBox tb = new TextBox();
        int width = (browseText == null) ? 330 : 246;
        tb.SetBounds(178, y, width, 23);
        Controls.Add(tb);

        if (browseText != null)
        {
            Button b = new Button();
            b.Text = browseText;
            b.SetBounds(430, y - 1, 78, 25);
            b.Click += delegate
            {
                using (FolderBrowserDialog dlg = new FolderBrowserDialog())
                {
                    dlg.Description = "Select the watch folder (network paths supported)";
                    dlg.ShowNewFolderButton = true;
                    try { if (tb.Text.Length > 0 && Directory.Exists(tb.Text)) dlg.SelectedPath = tb.Text; } catch { }
                    if (dlg.ShowDialog(this) == DialogResult.OK) tb.Text = dlg.SelectedPath;
                }
            };
            Controls.Add(b);
        }

        y += 30;
        return tb;
    }

    void LoadValues()
    {
        WatcherConfig c = WatcherConfig.Load(baseDir);
        tbIP.Text          = c.MachineIP;
        tbDest.Text        = c.DestinationFolder;
        tbWatch.Text       = c.WatchFolder;
        tbFilter.Text      = c.FileFilter;
        cbSubdirs.Checked  = c.IncludeSubdirectories;
        tbRetries.Text     = c.MaxRetries.ToString();
        tbDelay.Text       = c.RetryDelaySeconds.ToString();
        tbConnTimeout.Text = c.ConnectionTimeout.ToString();
        tbXferTimeout.Text = c.TransferTimeoutSeconds.ToString();
        cbToolMode.SelectedItem = (c.ToolTableTransferMode == "Overwrite") ? "Overwrite" : "Merge";
        loadedToolTableFolder = c.ToolTableFolder;
        cbStlEnable.Checked  = c.EnableStlTransfer;
        cbStlSidecar.Checked = c.StlUseSubfolderSidecarCheck;
        cbStlCut.Checked     = c.FixtureCutBelowAttach;
        tbClearance.Text     = c.FixtureClearanceMM.ToString(CultureInfo.InvariantCulture);
        tbSettle.Text        = c.NcSettleDelaySeconds.ToString(CultureInfo.InvariantCulture);
    }

    bool SaveAll()
    {
        string ip = tbIP.Text.Trim();
        string watch = tbWatch.Text.Trim();
        if (ip.Length == 0 || watch.Length == 0)
        {
            MessageBox.Show(this, "Machine IP and Watch folder are required.", "TNCWatcher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }

        int retries, delay, connT, xferT;
        if (!int.TryParse(tbRetries.Text.Trim(), out retries) ||
            !int.TryParse(tbDelay.Text.Trim(), out delay) ||
            !int.TryParse(tbConnTimeout.Text.Trim(), out connT) ||
            !int.TryParse(tbXferTimeout.Text.Trim(), out xferT))
        {
            MessageBox.Show(this, "Retries, delay and timeouts must be whole numbers.", "TNCWatcher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }

        double clearance;
        int settle;
        if (!double.TryParse(tbClearance.Text.Trim(), System.Globalization.NumberStyles.Float,
                CultureInfo.InvariantCulture, out clearance) || clearance < 0)
        {
            MessageBox.Show(this, "Fixture shrink must be a number in millimetres (0 disables shrinking).",
                "TNCWatcher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
        if (!int.TryParse(tbSettle.Text.Trim(), out settle) || settle < 0)
        {
            MessageBox.Show(this, "Program settle wait must be a whole number of seconds (0 disables it).",
                "TNCWatcher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }

        string user = tbNasUser.Text.Trim();
        string pass = tbNasPass.Text;
        if ((user.Length == 0) != (pass.Length == 0))
        {
            MessageBox.Show(this, "Enter BOTH NAS username and password, or leave both blank to keep the saved credential.",
                "TNCWatcher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }

        try
        {
            WatcherConfig c = new WatcherConfig();
            c.MachineIP = ip;
            c.DestinationFolder = tbDest.Text.Trim();
            c.WatchFolder = watch;
            c.FileFilter = (tbFilter.Text.Trim().Length == 0) ? "*.*" : tbFilter.Text.Trim();
            c.IncludeSubdirectories = cbSubdirs.Checked;
            c.MaxRetries = retries;
            c.RetryDelaySeconds = delay;
            c.ConnectionTimeout = connT;
            c.TransferTimeoutSeconds = xferT;
            c.ToolTableTransferMode = (cbToolMode.SelectedItem != null) ? cbToolMode.SelectedItem.ToString() : "Merge";
            c.ToolTableFolder = loadedToolTableFolder;
            c.EnableStlTransfer = cbStlEnable.Checked;
            c.StlUseSubfolderSidecarCheck = cbStlSidecar.Checked;
            c.FixtureCutBelowAttach = cbStlCut.Checked;
            c.FixtureClearanceMM = clearance;
            c.NcSettleDelaySeconds = settle;
            c.SaveJson(baseDir);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Could not save the config file:\n" + ex.Message, "TNCWatcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }

        if (user.Length > 0)
        {
            try
            {
                // DPAPI machine-bound; the elevated apply step moves it into
                // place and locks the ACL to SYSTEM + Administrators.
                byte[] plain = Encoding.UTF8.GetBytes(user + "\n" + pass);
                byte[] enc = ProtectedData.Protect(plain, null, DataProtectionScope.LocalMachine);
                File.WriteAllBytes(Path.Combine(baseDir, "service", "nas-credential.staged.bin"), enc);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Could not stage the NAS credential:\n" + ex.Message, "TNCWatcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }
        }

        return true;
    }

    void LaunchApply()
    {
        string helper = Path.Combine(baseDir, "service", "Apply-TrayConfig.ps1");
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + helper + "\"";
            psi.Verb = "runas";
            psi.UseShellExecute = true;
            Process.Start(psi);
        }
        catch
        {
            MessageBox.Show(this, "Admin prompt was declined - settings are saved but the service was NOT restarted.\nUse \"Restart Service\" in the tray menu to apply them later.",
                "TNCWatcher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    // Resolve the tool table folder from what's currently typed in the dialog,
    // so it tracks an edited (but unsaved) watch folder path.
    string CurrentToolTableFolder()
    {
        string folder = (loadedToolTableFolder == null || loadedToolTableFolder.Length == 0)
            ? "ToolTables" : loadedToolTableFolder;
        try { if (Path.IsPathRooted(folder)) return folder; } catch { }
        try { return Path.Combine(tbWatch.Text.Trim(), folder); } catch { return folder; }
    }

    void OpenToolTableFolder()
    {
        string folder = CurrentToolTableFolder();
        try
        {
            if (!Directory.Exists(folder)) Directory.CreateDirectory(folder);
            Process.Start("explorer.exe", "\"" + folder + "\"");
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Could not open the tool table folder:\n" + folder + "\n\n" + ex.Message,
                "TNCWatcher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    void BrowseAndSendToolTable()
    {
        string folder = CurrentToolTableFolder();
        using (OpenFileDialog dlg = new OpenFileDialog())
        {
            dlg.Title = "Select a tool table file to send";
            dlg.Filter = "Tool tables (*.t)|*.t|All files (*.*)|*.*";
            if (dlg.ShowDialog(this) != DialogResult.OK) return;

            string src = dlg.FileName;
            string dest = Path.Combine(folder, Path.GetFileName(src));
            try
            {
                if (!Directory.Exists(folder)) Directory.CreateDirectory(folder);

                if (File.Exists(dest))
                {
                    DialogResult r = MessageBox.Show(this,
                        Path.GetFileName(dest) + " is already in the tool table folder. Replace it and send again?",
                        "TNCWatcher", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                    if (r != DialogResult.Yes) return;
                }

                File.Copy(src, dest, true);
                MessageBox.Show(this,
                    "Copied " + Path.GetFileName(src) + " into the tool table folder.\n\n" +
                    "The watcher will back up the current remote table and send it (" +
                    (cbToolMode.SelectedItem != null ? cbToolMode.SelectedItem.ToString() : "Merge") +
                    " mode). Watch the tray/live log for progress.",
                    "TNCWatcher", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Could not copy the tool table into the folder:\n" + ex.Message,
                    "TNCWatcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Self-drawn toast window (bottom-right, above the tray)
//
// Independent of the Windows notification system, so it appears even when
// Settings > System > Notifications is turned off or Focus Assist is on -
// which is why NotifyIcon balloon tips were invisible on this PC. Does not
// steal keyboard focus (WS_EX_NOACTIVATE) so it won't interrupt an operator.
// ---------------------------------------------------------------------------
class ToastForm : Form
{
    readonly string titleText;
    readonly string bodyText;
    readonly Color accent;
    System.Windows.Forms.Timer lifeTimer;
    System.Windows.Forms.Timer fadeTimer;

    // Show without taking focus, and keep it out of Alt-Tab.
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
            return cp;
        }
    }

    public ToastForm(string title, string message, Color accentColor, int displayMs)
    {
        titleText = title == null ? "" : title;
        bodyText  = message == null ? "" : message;
        accent    = accentColor;

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar   = false;
        TopMost         = true;
        StartPosition   = FormStartPosition.Manual;
        BackColor       = Color.FromArgb(32, 32, 32);
        Width           = 360;
        Height          = 96;
        Opacity         = 0.96;
        DoubleBuffered  = true;

        Paint += OnPaintToast;
        // Click anywhere on the toast to dismiss it immediately.
        Click += delegate { CloseSafe(); };

        lifeTimer = new System.Windows.Forms.Timer();
        lifeTimer.Interval = Math.Max(1000, displayMs);
        lifeTimer.Tick += delegate { lifeTimer.Stop(); fadeTimer.Start(); };

        fadeTimer = new System.Windows.Forms.Timer();
        fadeTimer.Interval = 45;
        fadeTimer.Tick += delegate
        {
            if (Opacity <= 0.12) { fadeTimer.Stop(); CloseSafe(); }
            else { Opacity -= 0.12; }
        };
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        lifeTimer.Start();
    }

    void CloseSafe()
    {
        try { Close(); } catch { }
    }

    void OnPaintToast(object sender, PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

        using (Brush ab = new SolidBrush(accent))
            g.FillRectangle(ab, 0, 0, 5, Height);
        using (Pen bp = new Pen(Color.FromArgb(70, 70, 70)))
            g.DrawRectangle(bp, 0, 0, Width - 1, Height - 1);

        using (Brush tb = new SolidBrush(Color.White))
        using (Font tf = new Font("Segoe UI", 10.5F, FontStyle.Bold))
            g.DrawString(titleText, tf, tb, new RectangleF(16, 10, Width - 26, 24));

        using (Brush bb = new SolidBrush(Color.FromArgb(212, 212, 212)))
        using (Font bf = new Font("Segoe UI", 9F))
        using (StringFormat sf = new StringFormat())
        {
            sf.Trimming = StringTrimming.EllipsisWord;
            g.DrawString(bodyText, bf, bb, new RectangleF(16, 36, Width - 26, Height - 44), sf);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            if (lifeTimer != null) { lifeTimer.Dispose(); lifeTimer = null; }
            if (fadeTimer != null) { fadeTimer.Dispose(); fadeTimer = null; }
        }
        base.Dispose(disposing);
    }

    // Render the three sample toasts stacked into one PNG (verification aid).
    public static void SaveSamplePng(string path)
    {
        var samples = new[]
        {
            new object[] { "Transfer complete", "Sent to CNC: Ls Delrin Op2.h", Color.FromArgb(46, 204, 64) },
            new object[] { "Waiting to retry", "PartB.h is locked on the controller - still retrying (attempt 3/150). Set the machine to Manual to free it.", Color.FromArgb(255, 165, 0) },
            new object[] { "Machine unreachable", "PartC.h will be sent automatically once the machine is back online.", Color.FromArgb(224, 62, 45) },
        };

        int w = 360, h = 96, gap = 10;
        using (Bitmap canvas = new Bitmap(w, h * samples.Length + gap * (samples.Length + 1)))
        {
            using (Graphics cg = Graphics.FromImage(canvas))
                cg.Clear(Color.FromArgb(60, 60, 60)); // desktop-ish backdrop

            int y = gap;
            foreach (object[] s in samples)
            {
                using (ToastForm t = new ToastForm((string)s[0], (string)s[1], (Color)s[2], 1000))
                {
                    t.CreateControl();
                    using (Bitmap one = new Bitmap(w, h))
                    {
                        t.DrawToBitmap(one, new Rectangle(0, 0, w, h));
                        using (Graphics cg = Graphics.FromImage(canvas))
                            cg.DrawImage(one, gap, y);
                    }
                }
                y += h + gap;
            }
            canvas.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
    }
}

// ---------------------------------------------------------------------------
// Tray context
// ---------------------------------------------------------------------------
class TrayContext : ApplicationContext
{
    const string ServiceName = "TNCWatcher";
    const string RunKeyName  = "TNCWatcherTray";

    NotifyIcon trayIcon;
    System.Windows.Forms.Timer pollTimer;
    ToolStripMenuItem statusItem;
    ToolStripMenuItem lastSentItem;
    ToolStripMenuItem activityItem;
    ToolStripMenuItem startupItem;

    string baseDir;
    string logPath;
    string consoleCmd;

    string lastStatus = null;
    string lastLogLine = "";
    long logPos = -1;
    DateTime lastErrorBalloon = DateTime.MinValue;
    DateTime lastRetryBalloon = DateTime.MinValue;
    string currentFile = "";
    string lastOfflineToastFile = "";
    string lastSentFile = "";
    string lastSentTime = "";
    Icon currentIcon;
    SettingsForm settingsForm;

    // Self-drawn toast windows (bottom-right, above the tray). Used instead of
    // NotifyIcon balloon tips because those route through the Windows
    // notification system, which is disabled on this PC (Settings > System >
    // Notifications is off) - so balloons never appeared. These custom windows
    // show regardless of that setting or Focus Assist.
    readonly List<ToastForm> toasts = new List<ToastForm>();
    const int MaxVisibleToasts = 5;
    static readonly Color ToastGreen  = Color.FromArgb(46, 204, 64);
    static readonly Color ToastOrange = Color.FromArgb(255, 165, 0);
    static readonly Color ToastRed    = Color.FromArgb(224, 62, 45);

    // A "still retrying" toast for a LOCKED file (machine reachable) fires at
    // most once per this many seconds, so a long lock (e.g. NC program left in
    // Running mode) gives a periodic reminder without spamming every 30s.
    // The MACHINE-UNREACHABLE case is different: it toasts once per file and
    // never repeats (see lastOfflineToastFile).
    const int RetryBalloonCooldownSeconds = 240;

    public TrayContext()
    {
        baseDir    = AppDomain.CurrentDomain.BaseDirectory;
        logPath    = Path.Combine(baseDir, "TNCcmd-Watcher.log");
        consoleCmd = Path.Combine(baseDir, "TNCWatcher-Console.cmd");

        ContextMenuStrip menu = new ContextMenuStrip();
        statusItem = new ToolStripMenuItem("Service: ...");
        statusItem.Enabled = false;
        lastSentItem = new ToolStripMenuItem("Last sent: (none yet)");
        lastSentItem.Enabled = false;
        activityItem = new ToolStripMenuItem("");
        activityItem.Enabled = false;
        menu.Items.Add(statusItem);
        menu.Items.Add(lastSentItem);
        menu.Items.Add(activityItem);
        menu.Items.Add(new ToolStripSeparator());
        ToolStripMenuItem settingsMenuItem = new ToolStripMenuItem("Settings...", null, delegate { ShowSettings(); });
        settingsMenuItem.Font = new Font(SystemFonts.MenuFont, FontStyle.Bold);
        menu.Items.Add(settingsMenuItem);
        menu.Items.Add("Open Live Log Window", null, delegate { OpenConsole(); });
        menu.Items.Add("Open Watch Folder", null, delegate { OpenWatchFolder(); });
        menu.Items.Add("Restart Service (admin)", null, delegate { RestartService(); });
        menu.Items.Add(new ToolStripSeparator());
        startupItem = new ToolStripMenuItem("Start with Windows", null, delegate { ToggleStartup(); });
        menu.Items.Add(startupItem);
        menu.Items.Add("Exit monitor (service keeps running)", null, delegate { ExitApp(); });

        trayIcon = new NotifyIcon();
        trayIcon.ContextMenuStrip = menu;
        trayIcon.Visible = true;
        trayIcon.MouseClick += delegate(object s, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) ShowSettings();
        };
        trayIcon.DoubleClick += delegate { OpenConsole(); };

        EnsureStartupRegistered();
        UpdateStartupCheckmark();
        InitLastSentFromLog();

        pollTimer = new System.Windows.Forms.Timer();
        pollTimer.Interval = 3000;
        pollTimer.Tick += delegate { Poll(); };
        pollTimer.Start();
        Poll();
    }

    void ShowSettings()
    {
        if (settingsForm != null && !settingsForm.IsDisposed)
        {
            settingsForm.Activate();
            return;
        }
        settingsForm = new SettingsForm(baseDir);
        settingsForm.Show();
    }

    // ------------------------------------------------------------------ toasts

    void ShowToast(string title, string message, Color accent, int displayMs)
    {
        // Cap concurrent toasts so a burst can't cover the screen.
        while (toasts.Count >= MaxVisibleToasts)
        {
            ToastForm oldest = toasts[0];
            toasts.RemoveAt(0);
            try { oldest.Close(); } catch { }
        }

        ToastForm t = new ToastForm(title, message, accent, displayMs);
        t.FormClosed += delegate
        {
            toasts.Remove(t);
            ReflowToasts();
        };
        toasts.Add(t);
        ReflowToasts();
        t.Show();
    }

    // Stack toasts up from the bottom-right corner, newest nearest the tray.
    void ReflowToasts()
    {
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        int margin = 12;
        int y = wa.Bottom - margin;
        for (int i = toasts.Count - 1; i >= 0; i--)
        {
            ToastForm t = toasts[i];
            y -= t.Height;
            t.Left = wa.Right - t.Width - margin;
            t.Top = y;
            y -= 8; // gap between stacked toasts
        }
    }

    // ------------------------------------------------------------------ poll

    void Poll()
    {
        string status = GetServiceStatus();

        if (status != lastStatus)
        {
            bool firstPoll = (lastStatus == null);
            lastStatus = status;
            SetIconForStatus(status);
            if (!firstPoll)
            {
                Color c = (status == "Running") ? ToastGreen
                        : ((status == "Stopped" || status == "Not installed") ? ToastRed : ToastOrange);
                ShowToast("TNCWatcher", "Service is now: " + status, c, 5000);
            }
        }

        ReadNewLogLines();

        statusItem.Text = "Service: " + status;
        lastSentItem.Text = (lastSentFile.Length > 0)
            ? ("Last sent: " + Truncate(lastSentFile, 48) + "  (" + lastSentTime + ")")
            : "Last sent: (none yet)";
        activityItem.Text = Truncate(StripTimestamp(lastLogLine), 80);

        string tip = "TNCWatcher: " + status;
        string act = StripTimestamp(lastLogLine);
        if (act.Length > 0) tip = tip + "\n" + act;
        trayIcon.Text = Truncate(tip, 63);
    }

    string GetServiceStatus()
    {
        try
        {
            using (ServiceController sc = new ServiceController(ServiceName))
            {
                ServiceControllerStatus s = sc.Status; // throws if not installed
                switch (s)
                {
                    case ServiceControllerStatus.Running:        return "Running";
                    case ServiceControllerStatus.Stopped:        return "Stopped";
                    case ServiceControllerStatus.Paused:         return "Paused";
                    case ServiceControllerStatus.StartPending:   return "Starting";
                    case ServiceControllerStatus.StopPending:    return "Stopping";
                    case ServiceControllerStatus.PausePending:   return "Pausing";
                    case ServiceControllerStatus.ContinuePending:return "Resuming";
                    default: return s.ToString();
                }
            }
        }
        catch
        {
            return "Not installed";
        }
    }

    void ReadNewLogLines()
    {
        try
        {
            if (!File.Exists(logPath)) return;

            using (FileStream fs = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                long len = fs.Length;

                if (logPos < 0 || len < logPos)
                {
                    // First read (or the log rotated): show the last existing
                    // line but don't balloon about history.
                    long start = Math.Max(0, len - 4096);
                    fs.Seek(start, SeekOrigin.Begin);
                    string tailText = new StreamReader(fs, Encoding.Default).ReadToEnd();
                    string[] tailLines = tailText.Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
                    for (int i = tailLines.Length - 1; i >= 0; i--)
                    {
                        if (tailLines[i].Trim().Length > 0) { lastLogLine = tailLines[i]; break; }
                    }
                    logPos = len;
                    return;
                }

                if (len == logPos) return;

                fs.Seek(logPos, SeekOrigin.Begin);
                long toRead = Math.Min(len - logPos, 262144);
                byte[] buf = new byte[toRead];
                int read = fs.Read(buf, 0, (int)toRead);
                logPos = logPos + read;

                string text = Encoding.Default.GetString(buf, 0, read);
                string[] lines = text.Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
                foreach (string line in lines)
                {
                    string trimmed = line.Trim();
                    if (trimmed.Length == 0) continue;
                    // Skip blank log entries like "[ts] [INFO] "
                    if (Regex.IsMatch(trimmed, @"\[(INFO|DEBUG)\]\s*$")) continue;
                    lastLogLine = trimmed;

                    // Track the file currently being processed so a "waiting to
                    // retry" toast (whose own log line has no filename) can name it.
                    // A fresh "New file detected" also re-arms the once-per-file
                    // machine-unreachable toast.
                    Match dm = Regex.Match(trimmed, @"New file detected:\s*(.+?)\s*$");
                    if (dm.Success)
                    {
                        currentFile = dm.Groups[1].Value;
                        lastOfflineToastFile = "";
                    }
                    else
                    {
                        Match fm = Regex.Match(trimmed, @"Retry attempt \d+/\d+ for:\s*(.+?)\s*$");
                        if (!fm.Success) fm = Regex.Match(trimmed, @"Transferring:\s*(.+?)\s*->");
                        if (fm.Success) currentFile = fm.Groups[1].Value;
                    }

                    if (trimmed.Contains("[ERROR]") &&
                        (DateTime.Now - lastErrorBalloon).TotalSeconds > 30)
                    {
                        lastErrorBalloon = DateTime.Now;
                        ShowToast("TNCWatcher error", Truncate(StripTimestamp(trimmed), 200), ToastRed, 8000);
                    }
                    else if (trimmed.Contains("[SUCCESS]") && trimmed.ToLower().Contains("successful"))
                    {
                        // Transfer / tool-table completion (not MKDIR, backup, or
                        // NAS-auth successes, which don't contain "successful").
                        string name = ExtractAfterLastColon(StripTimestamp(trimmed));
                        if (name.Length > 0)
                        {
                            lastSentFile = name;
                            lastSentTime = ExtractTimestamp(trimmed);
                        }
                        string body = (name.Length > 0)
                            ? ("Sent to CNC: " + Truncate(name, 180))
                            : Truncate(StripTimestamp(trimmed), 200);
                        ShowToast("Transfer complete", body, ToastGreen, 5000);
                    }
                    else if (trimmed.ToLower().Contains("before retry"))
                    {
                        string who = (currentFile != null && currentFile.Length > 0) ? currentFile : "File";
                        Match am = Regex.Match(trimmed, @"attempt (\d+)/(\d+)");
                        string attempt = am.Success
                            ? (" (attempt " + am.Groups[1].Value + "/" + am.Groups[2].Value + ")")
                            : "";

                        if (trimmed.ToLower().Contains("unreachable"))
                        {
                            // Machine offline / not communicating: notify ONCE per
                            // file, then stay quiet until the next new file.
                            if (who != lastOfflineToastFile)
                            {
                                lastOfflineToastFile = who;
                                ShowToast("Machine unreachable",
                                    Truncate(who, 150) + " will be sent automatically once the machine is back online.",
                                    ToastOrange, 8000);
                            }
                        }
                        else if ((DateTime.Now - lastRetryBalloon).TotalSeconds > RetryBalloonCooldownSeconds)
                        {
                            // Machine reachable but the file is locked / in use
                            // (e.g. NC program still in Running mode): periodic
                            // reminder so it can be freed.
                            lastRetryBalloon = DateTime.Now;
                            ShowToast("Waiting to retry",
                                Truncate(who, 150) + " is locked on the controller — still retrying" + attempt
                                + ". Set the machine to Manual / close the program to free it.",
                                ToastOrange, 8000);
                        }
                    }
                }
            }
        }
        catch
        {
            // log briefly locked or unreadable - try again next tick
        }
    }

    // ------------------------------------------------------------------ icon

    void SetIconForStatus(string status)
    {
        Color c;
        if (status == "Running") c = Color.FromArgb(46, 204, 64);        // green
        else if (status == "Stopped" || status == "Not installed") c = Color.FromArgb(224, 62, 45); // red
        else c = Color.FromArgb(255, 165, 0);                            // orange

        Icon old = currentIcon;
        currentIcon = MakeCircleIcon(c);
        trayIcon.Icon = currentIcon;
        if (old != null) old.Dispose();
    }

    Icon MakeCircleIcon(Color color)
    {
        using (Bitmap bmp = new Bitmap(16, 16))
        {
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                using (Brush b = new SolidBrush(color))
                    g.FillEllipse(b, 1, 1, 13, 13);
                using (Pen p = new Pen(Color.FromArgb(90, Color.Black)))
                    g.DrawEllipse(p, 1, 1, 13, 13);
            }
            IntPtr hIcon = bmp.GetHicon();
            try
            {
                using (Icon tmp = Icon.FromHandle(hIcon))
                    return (Icon)tmp.Clone();
            }
            finally
            {
                NativeMethods.DestroyIcon(hIcon);
            }
        }
    }

    // ---------------------------------------------------------------- actions

    void OpenConsole()
    {
        try
        {
            if (File.Exists(consoleCmd))
            {
                ProcessStartInfo psi = new ProcessStartInfo(consoleCmd);
                psi.WorkingDirectory = baseDir;
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
            else if (File.Exists(logPath))
            {
                Process.Start("notepad.exe", "\"" + logPath + "\"");
            }
        }
        catch { }
    }

    void OpenWatchFolder()
    {
        try
        {
            WatcherConfig c = WatcherConfig.Load(baseDir);
            if (c.WatchFolder != null && c.WatchFolder.Length > 0)
                Process.Start("explorer.exe", "\"" + c.WatchFolder + "\"");
        }
        catch { }
    }

    void RestartService()
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -WindowStyle Hidden -Command \"Restart-Service " + ServiceName +
                            " -Force -ErrorAction SilentlyContinue; Start-Service " + ServiceName +
                            " -ErrorAction SilentlyContinue\"";
            psi.Verb = "runas";
            psi.UseShellExecute = true;
            Process.Start(psi);
        }
        catch
        {
            // user declined the UAC prompt - nothing to do
        }
    }

    // ---------------------------------------------------------------- startup

    void EnsureStartupRegistered()
    {
        try
        {
            using (RegistryKey rk = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
            {
                if (rk != null && rk.GetValue(RunKeyName) == null)
                    rk.SetValue(RunKeyName, "\"" + Application.ExecutablePath + "\"");
            }
        }
        catch { }
    }

    bool IsStartupRegistered()
    {
        try
        {
            using (RegistryKey rk = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", false))
            {
                return rk != null && rk.GetValue(RunKeyName) != null;
            }
        }
        catch { return false; }
    }

    void ToggleStartup()
    {
        try
        {
            using (RegistryKey rk = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
            {
                if (rk == null) return;
                if (rk.GetValue(RunKeyName) == null)
                    rk.SetValue(RunKeyName, "\"" + Application.ExecutablePath + "\"");
                else
                    rk.DeleteValue(RunKeyName, false);
            }
        }
        catch { }
        UpdateStartupCheckmark();
    }

    void UpdateStartupCheckmark()
    {
        startupItem.Checked = IsStartupRegistered();
    }

    // ----------------------------------------------------------------- misc

    static string StripTimestamp(string line)
    {
        if (line == null) return "";
        // "[2026-07-02 16:21:37] [INFO] msg" -> "[INFO] msg"
        return Regex.Replace(line, @"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]\s*", "");
    }

    static string Truncate(string s, int max)
    {
        if (s == null) return "";
        if (s.Length <= max) return s;
        return s.Substring(0, max - 1) + "…";
    }

    // "[SUCCESS] Transfer successful after 4 attempts: NAME.h" -> "NAME.h"
    static string ExtractAfterLastColon(string s)
    {
        if (s == null) return "";
        int i = s.LastIndexOf(": ");
        if (i >= 0 && i + 2 <= s.Length) return s.Substring(i + 2).Trim();
        return "";
    }

    // "[2026-07-02 16:40:48] [SUCCESS] ..." -> "2026-07-02 16:40:48"
    static string ExtractTimestamp(string line)
    {
        if (line == null) return "";
        Match m = Regex.Match(line, @"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]");
        return m.Success ? m.Groups[1].Value : "";
    }

    // Populate "Last sent" from the log's history at startup, so the menu is
    // useful immediately rather than only after the next transfer this session.
    void InitLastSentFromLog()
    {
        try
        {
            if (!File.Exists(logPath)) return;
            using (FileStream fs = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                long len = fs.Length;
                long start = Math.Max(0, len - 1048576); // scan the last 1 MB
                fs.Seek(start, SeekOrigin.Begin);
                string text = new StreamReader(fs, Encoding.Default).ReadToEnd();
                string[] lines = text.Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
                for (int i = lines.Length - 1; i >= 0; i--)
                {
                    string t = lines[i].Trim();
                    if (t.Contains("[SUCCESS]") && t.ToLower().Contains("successful"))
                    {
                        string name = ExtractAfterLastColon(StripTimestamp(t));
                        if (name.Length > 0)
                        {
                            lastSentFile = name;
                            lastSentTime = ExtractTimestamp(t);
                        }
                        break;
                    }
                }
            }
        }
        catch { }
    }

    void ExitApp()
    {
        pollTimer.Stop();
        foreach (ToastForm t in toasts.ToArray())
        {
            try { t.Close(); } catch { }
        }
        trayIcon.Visible = false;
        trayIcon.Dispose();
        if (currentIcon != null) currentIcon.Dispose();
        Application.Exit();
    }
}
