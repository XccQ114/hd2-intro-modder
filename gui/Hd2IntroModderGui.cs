// Hd2IntroModderGui.cs - WinForms front-end for build-mod.ps1 (hd2-intro-modder).
// Compiled into a single .EXE with the .NET Framework csc.exe (no SDK, no extra runtime).
//
// Design notes (all three points were verified experimentally before writing this):
//  1. This GUI does NOT reimplement the pipeline. It runs the already game-tested
//     build-mod.ps1 and streams its console output into the log pane. Keeping one
//     implementation means the GUI can never drift from the script.
//  2. PowerShell 5.1 writes to a redirected pipe using the system ANSI code page
//     (measured: GBK/936 on a Chinese Windows). StandardOutputEncoding must be set
//     to that same code page, otherwise every Chinese line becomes mojibake.
//  3. build-mod.ps1 pauses with Read-Host at every exit point. Closing the child's
//     stdin right after start makes Read-Host return immediately instead of hanging
//     the GUI forever waiting for a keypress nobody can give.
//
// The dependency panel follows the same rule as (1): tools\deps.ps1 owns the whole
// detection / mirror-probing / download logic, this window only drives it and renders
// the result. deps.ps1 is kept pure ASCII (Windows PowerShell parses BOM-less scripts
// with the ANSI code page), so every Chinese string shown here is keyed by dependency id.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace Hd2IntroModder
{
    public class MainForm : Form
    {
        private TextBox txtVideo;
        private TextBox txtWem;
        private NumericUpDown numPatch;
        private CheckBox chkZip;
        private Button btnStart;
        private Button btnOpenOut;
        private Button btnDeps;
        private RichTextBox txtLog;
        private Label lblStatus;
        private Label lblHint;

        private string rootDir = "";
        private string scriptPath = "";
        private Process proc;

        private const int MaxLogChars = 400000;   // keep the RichTextBox responsive

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [STAThread]
        public static void Main()
        {
            try { SetProcessDPIAware(); } catch { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }

        public MainForm()
        {
            Text = "hd2-intro-modder - HD2 intro mod generator";
            ClientSize = new Size(860, 640);
            MinimumSize = new Size(720, 500);
            StartPosition = FormStartPosition.CenterScreen;
            Font = SystemFonts.MessageBoxFont;
            AllowDrop = true;

            // ---------- source video ----------
            Label l1 = new Label();
            l1.Text = "源视频 (MP4)  -  也可以直接把文件拖进本窗口";
            l1.Location = new Point(14, 14);
            l1.AutoSize = true;
            Controls.Add(l1);

            txtVideo = new TextBox();
            txtVideo.Location = new Point(14, 36);
            txtVideo.Width = 700;
            txtVideo.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            Controls.Add(txtVideo);

            Button btnVideo = new Button();
            btnVideo.Text = "浏览...";
            btnVideo.Location = new Point(722, 34);
            btnVideo.Size = new Size(124, 26);
            btnVideo.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            btnVideo.Click += delegate { BrowseInto(txtVideo, "MP4 视频 (*.mp4)|*.mp4|所有文件 (*.*)|*.*"); };
            Controls.Add(btnVideo);

            // ---------- options ----------
            Label l2 = new Label();
            l2.Text = "Patch 编号";
            l2.Location = new Point(14, 78);
            l2.AutoSize = true;
            Controls.Add(l2);

            numPatch = new NumericUpDown();
            numPatch.Location = new Point(90, 75);
            numPatch.Width = 64;
            numPatch.Minimum = 0;
            numPatch.Maximum = 999;
            numPatch.Value = 0;
            Controls.Add(numPatch);

            Label l3 = new Label();
            l3.Text = "（用 HD2MM 等管理器安装时保持 0 即可，管理器会自行重排编号）";
            l3.Location = new Point(164, 78);
            l3.AutoSize = true;
            l3.ForeColor = SystemColors.GrayText;
            Controls.Add(l3);

            chkZip = new CheckBox();
            chkZip.Text = "额外打包成 zip";
            chkZip.Location = new Point(14, 106);
            chkZip.AutoSize = true;
            Controls.Add(chkZip);

            Label l4 = new Label();
            l4.Text = "现成 wem 音频 (可选，留空则用 Wwise 从视频音轨转换)";
            l4.Location = new Point(14, 138);
            l4.AutoSize = true;
            Controls.Add(l4);

            txtWem = new TextBox();
            txtWem.Location = new Point(14, 160);
            txtWem.Width = 700;
            txtWem.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            Controls.Add(txtWem);

            Button btnWem = new Button();
            btnWem.Text = "浏览...";
            btnWem.Location = new Point(722, 158);
            btnWem.Size = new Size(124, 26);
            btnWem.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            btnWem.Click += delegate { BrowseInto(txtWem, "Wwise 音频 (*.wem)|*.wem|所有文件 (*.*)|*.*"); };
            Controls.Add(btnWem);

            // ---------- action row ----------
            btnStart = new Button();
            btnStart.Text = "开始生成";
            btnStart.Location = new Point(14, 200);
            btnStart.Size = new Size(150, 34);
            btnStart.Click += delegate { StartBuild(); };
            Controls.Add(btnStart);

            btnOpenOut = new Button();
            btnOpenOut.Text = "打开输出目录";
            btnOpenOut.Location = new Point(176, 200);
            btnOpenOut.Size = new Size(150, 34);
            btnOpenOut.Click += delegate { OpenOutputDir(); };
            Controls.Add(btnOpenOut);

            btnDeps = new Button();
            btnDeps.Text = "依赖检查";
            btnDeps.Location = new Point(338, 200);
            btnDeps.Size = new Size(150, 34);
            btnDeps.Click += delegate { OpenDeps(); };
            Controls.Add(btnDeps);

            lblStatus = new Label();
            lblStatus.Text = "就绪";
            lblStatus.Location = new Point(502, 210);
            lblStatus.AutoSize = true;
            lblStatus.Font = new Font(SystemFonts.MessageBoxFont, FontStyle.Bold);
            Controls.Add(lblStatus);

            lblHint = new Label();
            lblHint.Text = "";
            lblHint.Location = new Point(14, 240);
            lblHint.AutoSize = true;
            lblHint.ForeColor = SystemColors.GrayText;
            Controls.Add(lblHint);

            // ---------- log ----------
            txtLog = new RichTextBox();
            txtLog.Location = new Point(14, 264);
            txtLog.Size = new Size(832, 360);
            txtLog.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
            txtLog.ReadOnly = true;
            txtLog.BackColor = Color.FromArgb(20, 20, 20);
            txtLog.ForeColor = Color.Gainsboro;
            txtLog.Font = new Font("Consolas", 9F);
            txtLog.WordWrap = false;
            txtLog.ScrollBars = RichTextBoxScrollBars.Both;
            txtLog.DetectUrls = false;
            Controls.Add(txtLog);

            DragEnter += OnDragEnter;
            DragDrop += OnDragDrop;
            FormClosing += OnFormClosing;

            LocateScript();
        }

        private void OnDragEnter(object sender, DragEventArgs e)
        {
            if (e.Data.GetDataPresent(DataFormats.FileDrop)) e.Effect = DragDropEffects.Copy;
        }

        private void OnDragDrop(object sender, DragEventArgs e)
        {
            string[] files = e.Data.GetData(DataFormats.FileDrop) as string[];
            if (files != null && files.Length > 0) txtVideo.Text = files[0];
        }

        private void OnFormClosing(object sender, FormClosingEventArgs e)
        {
            if (proc == null || proc.HasExited) return;
            DialogResult r = MessageBox.Show(this,
                "生成任务仍在运行。强行关闭会中断编码（可能留下临时文件）。确定关闭吗？",
                "任务进行中", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (r != DialogResult.Yes) { e.Cancel = true; return; }
            try { proc.Kill(); } catch { }
        }

        // ------------------------------------------------------------------
        private void LocateScript()
        {
            string exeDir = Path.GetDirectoryName(Application.ExecutablePath);
            string[] candidates = new string[]
            {
                Path.Combine(exeDir, "build-mod.ps1"),
                Path.Combine(Path.Combine(exeDir, ".."), "build-mod.ps1"),
                Path.Combine(Path.Combine(Path.Combine(exeDir, ".."), ".."), "build-mod.ps1")
            };
            foreach (string c in candidates)
            {
                string full = Path.GetFullPath(c);
                if (File.Exists(full))
                {
                    scriptPath = full;
                    rootDir = Path.GetDirectoryName(full);
                    break;
                }
            }
            if (scriptPath == "")
            {
                lblStatus.Text = "未找到 build-mod.ps1";
                lblHint.Text = "请把本 EXE 放在 hd2-intro-modder 项目目录（与 build-mod.ps1 同级）后重新运行。";
                btnStart.Enabled = false;
                btnDeps.Enabled = false;
                AppendLog("[ERROR] build-mod.ps1 not found next to the EXE.");
                AppendLog("        exe dir: " + exeDir);
            }
            else
            {
                AppendLog("hd2-intro-modder GUI");
                AppendLog("  脚本: " + scriptPath);
                AppendLog("  输出目录: " + Path.Combine(rootDir, "output"));
                AppendLog("");
                AppendLog("先选一个 MP4，然后点「开始生成」。编码期间 radvideo64 会弹出它自己的窗口，属正常现象。");
                AppendLog("");
                CheckDepsQuietly();
            }
        }

        /// <summary>Runs the dependency check off the UI thread and reports any gap.</summary>
        private void CheckDepsQuietly()
        {
            string depsScript = Path.Combine(Path.Combine(rootDir, "tools"), "deps.ps1");
            if (!File.Exists(depsScript)) return;
            System.Threading.ThreadPool.QueueUserWorkItem(delegate
            {
                List<DepInfo> list = DepsForm.QueryDeps(depsScript);
                if (list == null) return;
                int missing = 0;
                int missingAuto = 0;
                foreach (DepInfo d in list)
                {
                    if (!d.Installed)
                    {
                        missing++;
                        if (d.Auto) missingAuto++;
                    }
                }
                try
                {
                    BeginInvoke(new Action(delegate
                    {
                        if (missing == 0)
                        {
                            btnDeps.Text = "依赖检查 (齐全)";
                        }
                        else
                        {
                            btnDeps.Text = "依赖检查 (" + missing + " 项缺失)";
                            btnDeps.ForeColor = Color.Firebrick;
                            lblStatus.Text = "缺少 " + missing + " 项依赖";
                            lblHint.Text = missingAuto > 0
                                ? "有 " + missingAuto + " 项可以由本程序代为下载：请点「依赖检查」。"
                                : "请点「依赖检查」查看缺什么以及在哪里获取。";
                        }
                    }));
                }
                catch { }
            });
        }

        private void OpenDeps()
        {
            string depsScript = Path.Combine(Path.Combine(rootDir, "tools"), "deps.ps1");
            if (!File.Exists(depsScript))
            {
                MessageBox.Show(this, "找不到 tools\\deps.ps1。\r\n请确认使用的是完整发布包。", "缺少文件",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            using (DepsForm f = new DepsForm(depsScript, rootDir))
            {
                f.ShowDialog(this);
            }
            btnDeps.ForeColor = SystemColors.ControlText;
            btnDeps.Text = "依赖检查";
            CheckDepsQuietly();
        }

        private void BrowseInto(TextBox target, string filter)
        {
            using (OpenFileDialog dlg = new OpenFileDialog())
            {
                dlg.Filter = filter;
                dlg.Title = "选择文件";
                string cur = target.Text.Trim();
                if (cur != "" && File.Exists(cur))
                {
                    dlg.InitialDirectory = Path.GetDirectoryName(cur);
                    dlg.FileName = Path.GetFileName(cur);
                }
                if (dlg.ShowDialog(this) == DialogResult.OK) target.Text = dlg.FileName;
            }
        }

        private void OpenOutputDir()
        {
            string dir = rootDir == "" ? "" : Path.Combine(rootDir, "output");
            if (dir == "" || !Directory.Exists(dir)) dir = rootDir;
            if (dir == "" || !Directory.Exists(dir))
            {
                MessageBox.Show(this, "还没有输出目录。", "提示", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            try { Process.Start("explorer.exe", "\"" + dir + "\""); }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, "无法打开目录"); }
        }

        internal static Encoding ConsoleEncoding()
        {
            // PowerShell 5.1 writes redirected output in the system ANSI code page.
            try
            {
                int cp = CultureInfo.CurrentCulture.TextInfo.ANSICodePage;
                return Encoding.GetEncoding(cp);
            }
            catch { return Encoding.Default; }
        }

        /// <summary>Returns an error message, or null when the given inputs are usable.</summary>
        private string ValidateInputs(out string video, out string wem)
        {
            video = txtVideo.Text.Trim();
            wem = txtWem.Text.Trim();
            if (video == "") return "请先选择源视频（MP4）。";
            if (!File.Exists(video)) return "找不到这个文件：\r\n" + video;
            if (wem != "" && !File.Exists(wem)) return "找不到这个 wem 文件：\r\n" + wem;
            return null;
        }

        /// <summary>Builds the PowerShell command line that runs build-mod.ps1.</summary>
        private string BuildArguments(string video, string wem)
        {
            StringBuilder a = new StringBuilder();
            a.Append("-NoProfile -ExecutionPolicy Bypass -File \"");
            a.Append(scriptPath);
            a.Append("\" -Video \"");
            a.Append(video);
            a.Append("\"");
            if (numPatch.Value > 0) a.Append(" -Num " + ((int)numPatch.Value).ToString(CultureInfo.InvariantCulture));
            if (chkZip.Checked) a.Append(" -Zip");
            if (wem != "") a.Append(" -Wem \"" + wem + "\"");
            return a.ToString();
        }

        private void StartBuild()
        {
            if (proc != null && !proc.HasExited) return;

            string video, wem;
            string problem = ValidateInputs(out video, out wem);
            if (problem != null)
            {
                MessageBox.Show(this, problem, "输入有误", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            string arguments = BuildArguments(video, wem);
            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", arguments);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            Encoding enc = ConsoleEncoding();
            psi.StandardOutputEncoding = enc;
            psi.StandardErrorEncoding = enc;

            txtLog.Clear();
            AppendLog("$ powershell.exe " + arguments);
            AppendLog("");

            try
            {
                proc = new Process();
                proc.StartInfo = psi;
                proc.EnableRaisingEvents = true;
                proc.OutputDataReceived += OnProcessOutput;
                proc.ErrorDataReceived += OnProcessOutput;
                proc.Exited += delegate(object s, EventArgs e)
                {
                    int code = -1;
                    try { code = proc.ExitCode; } catch { }
                    BeginInvoke(new Action<int>(BuildFinished), code);
                };
                proc.Start();
                // Read-Host in build-mod.ps1 must not block: give it EOF immediately.
                try { proc.StandardInput.Close(); } catch { }
                proc.BeginOutputReadLine();
                proc.BeginErrorReadLine();

                btnStart.Enabled = false;
                btnStart.Text = "生成中...";
                lblStatus.Text = "运行中";
                lblHint.Text = "radvideo64 会弹出自己的编码窗口，编码完成后脚本会自动关闭它。请勿手动关闭该窗口。";
            }
            catch (Exception ex)
            {
                AppendLog("[ERROR] 无法启动 PowerShell: " + ex.Message);
                lblStatus.Text = "启动失败";
                btnStart.Enabled = true;
                btnStart.Text = "开始生成";
            }
        }

        /// <summary>Streams one line of the child process output into the log pane.</summary>
        private void OnProcessOutput(object sender, DataReceivedEventArgs e)
        {
            if (e.Data != null) AppendLog(e.Data);
        }

        private void BuildFinished(int exitCode)
        {
            btnStart.Enabled = true;
            btnStart.Text = "开始生成";
            if (exitCode == 0)
            {
                lblStatus.Text = "完成 (exit 0)";
                lblHint.Text = "产物在 output\\ 下的以视频名命名的子目录里，可直接复制进游戏的 'Helldivers 2\\data\\'。";
            }
            else
            {
                lblStatus.Text = "失败 (exit " + exitCode + ")";
                lblHint.Text = "脚本拒绝输出不可用的成品。看上面的日志：若提示缺少依赖，请点「依赖检查」。";
            }
        }

        private void AppendLog(string line)
        {
            if (txtLog.InvokeRequired)
            {
                try { txtLog.BeginInvoke(new Action<string>(AppendLog), line); } catch { }
                return;
            }
            if (txtLog.TextLength > MaxLogChars)
            {
                txtLog.Select(0, MaxLogChars / 4);
                txtLog.SelectedText = "";
            }
            txtLog.AppendText(line + "\r\n");
            txtLog.SelectionStart = txtLog.TextLength;
            txtLog.ScrollToCaret();
        }
    }

    /// <summary>One dependency as reported by tools\deps.ps1.</summary>
    public class DepInfo
    {
        public string Id = "";
        public string Name = "";
        public bool Installed;
        public bool Auto;
        public string Condition = "";
        public string Note = "";
        public string Url = "";
        public string Path = "";
        public string[] Sources = new string[0];
    }

    /// <summary>
    /// Dependency panel. Detection, mirror probing and downloading are all performed by
    /// tools\deps.ps1; this window only renders the result and asks the user before any
    /// download happens.
    /// </summary>
    public class DepsForm : Form
    {
        private DataGridView grid;
        private TextBox txtLog;
        private Button btnTest;
        private Button btnDownload;
        private Button btnRefresh;
        private Button btnClose;
        private Label lblRoot;
        private Label lblDetail;

        private readonly string depsScript;
        private readonly string projectRoot;
        private Process proc;
        private List<DepInfo> deps = new List<DepInfo>();
        private string depsRoot = "";

        public DepsForm(string depsScriptPath, string projectRootDir)
        {
            depsScript = depsScriptPath;
            projectRoot = projectRootDir;

            Text = "依赖检查 - hd2-intro-modder";
            ClientSize = new Size(880, 640);
            MinimumSize = new Size(760, 520);
            StartPosition = FormStartPosition.CenterParent;
            Font = SystemFonts.MessageBoxFont;
            ShowInTaskbar = false;

            Label l1 = new Label();
            l1.Text = "生成一个游戏内可用的 mod 需要以下依赖。标记为「可代下载」的项，"
                + "在你确认后由本程序下载并解压到下面的目录（不写系统盘）。";
            l1.Location = new Point(14, 12);
            l1.Size = new Size(852, 32);
            l1.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            Controls.Add(l1);

            lblRoot = new Label();
            lblRoot.Text = "下载目录：检测中...";
            lblRoot.Location = new Point(14, 46);
            lblRoot.AutoSize = true;
            lblRoot.ForeColor = SystemColors.GrayText;
            Controls.Add(lblRoot);

            grid = new DataGridView();
            grid.Location = new Point(14, 70);
            grid.Size = new Size(852, 236);
            grid.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            grid.AllowUserToAddRows = false;
            grid.AllowUserToDeleteRows = false;
            grid.AllowUserToResizeRows = false;
            grid.RowHeadersVisible = false;
            grid.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
            grid.MultiSelect = false;
            grid.BackgroundColor = SystemColors.Window;
            grid.EditMode = DataGridViewEditMode.EditOnKeystrokeOrF2;
            // Cell text used to be clipped to "4304..." (a full URL, or "官网 可达 000 · 4304ms").
            // Wrap it and let the row grow taller instead of truncating, and let the address
            // column absorb horizontal resizing so the table tracks the window width.
            grid.AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.AllCells;
            grid.DefaultCellStyle.WrapMode = DataGridViewTriState.True;
            grid.ShowCellToolTips = true;
            grid.SelectionChanged += delegate { ShowDetail(); };

            DataGridViewTextBoxColumn cName = new DataGridViewTextBoxColumn();
            cName.Name = "name";
            cName.HeaderText = "依赖";
            cName.Width = 190;
            cName.ReadOnly = true;
            grid.Columns.Add(cName);

            DataGridViewTextBoxColumn cState = new DataGridViewTextBoxColumn();
            cState.Name = "state";
            cState.HeaderText = "状态";
            cState.Width = 70;
            cState.ReadOnly = true;
            grid.Columns.Add(cState);

            DataGridViewCheckBoxColumn cPick = new DataGridViewCheckBoxColumn();
            cPick.Name = "pick";
            cPick.HeaderText = "下载";
            cPick.Width = 45;
            grid.Columns.Add(cPick);

            DataGridViewTextBoxColumn cUrl = new DataGridViewTextBoxColumn();
            cUrl.Name = "url";
            cUrl.HeaderText = "下载地址（可自行改成你信任的镜像）";
            // Fill so this column takes (or gives back) every pixel the window gains or loses;
            // the other columns keep fixed widths.
            cUrl.AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill;
            cUrl.FillWeight = 100;
            cUrl.MinimumWidth = 180;
            grid.Columns.Add(cUrl);

            DataGridViewTextBoxColumn cReach = new DataGridViewTextBoxColumn();
            cReach.Name = "reach";
            cReach.HeaderText = "源可达性";
            cReach.Width = 140;
            cReach.ReadOnly = true;
            grid.Columns.Add(cReach);

            Controls.Add(grid);

            btnTest = new Button();
            btnTest.Text = "检测下载源";
            btnTest.Location = new Point(14, 314);
            btnTest.Size = new Size(120, 30);
            btnTest.Click += delegate { RunTestSources(); };
            Controls.Add(btnTest);

            btnDownload = new Button();
            btnDownload.Text = "下载所选...";
            btnDownload.Location = new Point(144, 314);
            btnDownload.Size = new Size(120, 30);
            btnDownload.Click += delegate { RunDownload(); };
            Controls.Add(btnDownload);

            btnRefresh = new Button();
            btnRefresh.Text = "刷新";
            btnRefresh.Location = new Point(274, 314);
            btnRefresh.Size = new Size(90, 30);
            btnRefresh.Click += delegate { RunCheck(); };
            Controls.Add(btnRefresh);

            btnClose = new Button();
            btnClose.Text = "关闭";
            btnClose.Location = new Point(776, 314);
            btnClose.Size = new Size(90, 30);
            btnClose.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            btnClose.Click += delegate { Close(); };
            Controls.Add(btnClose);

            // The detail text length varies a lot (a long Wwise sentence plus a full install
            // path), so its height is computed from the wrapped text and the log pane below
            // follows it - see ReflowDetail().
            lblDetail = new Label();
            lblDetail.Location = new Point(14, 352);
            lblDetail.Size = new Size(852, 34);
            lblDetail.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            lblDetail.ForeColor = SystemColors.GrayText;
            lblDetail.Text = "";
            Controls.Add(lblDetail);

            txtLog = new TextBox();
            txtLog.Location = new Point(14, 394);
            txtLog.Size = new Size(852, 232);
            // Height is driven by ReflowDetail(), so no Bottom anchor here.
            txtLog.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            txtLog.Multiline = true;
            txtLog.ReadOnly = true;
            txtLog.ScrollBars = ScrollBars.Both;
            txtLog.WordWrap = false;
            txtLog.BackColor = Color.FromArgb(20, 20, 20);
            txtLog.ForeColor = Color.Gainsboro;
            txtLog.Font = new Font("Consolas", 9F);
            Controls.Add(txtLog);

            FormClosing += OnFormClosing;
            Resize += delegate { ReflowDetail(); };
            Load += delegate { RunCheck(); };
        }

        /// <summary>
        /// Sizes the detail label to the wrapped height of its text and pushes the log pane
        /// down accordingly. Long entries (Wwise + a deep install path) used to be clipped.
        /// </summary>
        private void ReflowDetail()
        {
            string t = lblDetail.Text;
            if (t == null) t = "";
            int w = Math.Max(160, lblDetail.Width);
            int want;
            if (t.Length == 0)
            {
                want = 32;
            }
            else
            {
                // Measure without NoPadding: Label rendering needs at least the padded
                // height, and under-measuring here is exactly what clipped the Wwise text.
                Size sz = TextRenderer.MeasureText(t, lblDetail.Font, new Size(w, 4000),
                    TextFormatFlags.WordBreak);
                want = Math.Max(32, sz.Height + 8);
            }
            if (want != lblDetail.Height) lblDetail.Height = want;

            int logTop = lblDetail.Bottom + 8;
            int logHeight = ClientSize.Height - logTop - 14;
            if (logHeight < 70) logHeight = 70;
            txtLog.Location = new Point(txtLog.Left, logTop);
            txtLog.Size = new Size(txtLog.Width, logHeight);
        }

        private void OnFormClosing(object sender, FormClosingEventArgs e)
        {
            if (proc == null || proc.HasExited) return;
            DialogResult r = MessageBox.Show(this,
                "依赖下载仍在进行。强行关闭会中断下载（已下载的部分会被丢弃）。确定关闭吗？",
                "下载进行中", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (r != DialogResult.Yes) { e.Cancel = true; return; }
            try { proc.Kill(); } catch { }
        }

        // ------------------------------------------------------------ ps helpers

        private string PsArguments(string tail)
        {
            return "-NoProfile -ExecutionPolicy Bypass -File \"" + depsScript + "\" " + tail;
        }

        /// <summary>Runs deps.ps1 synchronously and returns its stdout lines.</summary>
        private List<string> RunSync(string tail)
        {
            List<string> lines = new List<string>();
            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", PsArguments(tail));
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            Encoding enc = MainForm.ConsoleEncoding();
            psi.StandardOutputEncoding = enc;
            psi.StandardErrorEncoding = enc;
            Process p = new Process();
            p.StartInfo = psi;
            try
            {
                p.Start();
                try { p.StandardInput.Close(); } catch { }
                string stdout = p.StandardOutput.ReadToEnd();
                p.WaitForExit();
                foreach (string s in stdout.Split('\n'))
                {
                    string t = s.TrimEnd('\r');
                    if (t.Length > 0) lines.Add(t);
                }
            }
            catch (Exception ex)
            {
                lines.Add("[ERROR] " + ex.Message);
            }
            finally
            {
                try { p.Dispose(); } catch { }
            }
            return lines;
        }

        /// <summary>Static variant used by the main window for its quiet startup check.</summary>
        public static List<DepInfo> QueryDeps(string depsScriptPath)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -File \"" + depsScriptPath + "\" -Check -Lines");
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardInput = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                Encoding enc = MainForm.ConsoleEncoding();
                psi.StandardOutputEncoding = enc;
                psi.StandardErrorEncoding = enc;
                Process p = new Process();
                p.StartInfo = psi;
                p.Start();
                try { p.StandardInput.Close(); } catch { }
                string stdout = p.StandardOutput.ReadToEnd();
                p.WaitForExit();
                p.Dispose();
                return ParseDeps(stdout.Split('\n'), null);
            }
            catch { return null; }
        }

        private static Dictionary<string, string> ParseFields(string line)
        {
            Dictionary<string, string> d = new Dictionary<string, string>();
            string[] parts = line.Split('|');
            for (int i = 1; i < parts.Length; i++)
            {
                int eq = parts[i].IndexOf('=');
                if (eq > 0) d[parts[i].Substring(0, eq)] = parts[i].Substring(eq + 1);
            }
            return d;
        }

        private static string Field(Dictionary<string, string> f, string key)
        {
            return f.ContainsKey(key) ? f[key] : null;
        }

        /// <summary>Maps one DEP| line onto a DepInfo. Absent fields keep their defaults.</summary>
        private static DepInfo ParseDepLine(string line)
        {
            Dictionary<string, string> f = ParseFields(line);
            DepInfo d = new DepInfo();
            d.Id = Field(f, "id") ?? "";
            d.Name = Field(f, "name") ?? "";
            d.Installed = Field(f, "installed") == "1";
            d.Auto = Field(f, "auto") == "1";
            d.Condition = Field(f, "condition") ?? "";
            d.Note = Field(f, "note") ?? "";
            d.Url = Field(f, "url") ?? "";
            d.Path = Field(f, "path") ?? "";
            string sources = Field(f, "sources");
            if (sources != null && sources.Length > 0) d.Sources = sources.Split(';');
            return d;
        }

        /// <summary>Fills the CHECK| line's root/game-dir slots.</summary>
        private static void ParseCheckLine(string line, string[] rootOut)
        {
            Dictionary<string, string> f = ParseFields(line);
            string depsRoot = Field(f, "depsRoot");
            string gameDir = Field(f, "gameDir");
            if (depsRoot != null) rootOut[0] = depsRoot;
            if (gameDir != null && rootOut.Length > 1) rootOut[1] = gameDir;
        }

        private static List<DepInfo> ParseDeps(string[] lines, string[] rootOut)
        {
            List<DepInfo> list = new List<DepInfo>();
            foreach (string raw in lines)
            {
                string line = raw.TrimEnd('\r');
                if (line.Length == 0) continue;
                if (line.StartsWith("DEP|")) list.Add(ParseDepLine(line));
                else if (line.StartsWith("CHECK|") && rootOut != null) ParseCheckLine(line, rootOut);
            }
            return list;
        }

        // ------------------------------------------------------------ localized text
        // deps.ps1 is pure ASCII on purpose; the Chinese wording lives here, keyed by id.

        private static string ZhName(string id)
        {
            switch (id)
            {
                case "radvideo64": return "RAD Video Tools（编码器）";
                case "python": return "Python 3（打包）";
                case "ffmpeg": return "ffmpeg + ffprobe（分辨率）";
                case "wwise": return "Wwise（音频转 wem）";
                case "binkdll": return "bink2w64.dll（游戏自带）";
            }
            return id;
        }

        private static string ZhCondition(string id)
        {
            switch (id)
            {
                case "radvideo64": return "必需：把视频压成游戏能读的 Bink 格式（bink2c）。缺少则无法生成。";
                case "python": return "必需：打包 patch 容器。免安装版即可，本项目脚本只用标准库。";
                case "ffmpeg": return "必需：低于 720p 要重压（否则游戏内花屏）、超过 1440p/60fps 要降级（否则编码时间过长）。";
                case "wwise": return "必需：把视频音轨转成游戏读取的 .wem。若你已有现成 wem，可用「现成 wem」栏跳过。";
                case "binkdll": return "必需：从 .bk2 提取 BINK 音轨；缺失时最终的全帧解码校验会被跳过。";
            }
            return "";
        }

        private static string ZhNote(string id, string installedPath)
        {
            switch (id)
            {
                case "radvideo64":
                    return "商业软件（可免费使用）。官方只提供安装程序，无法代下载。装完重开本窗口即可识别。";
                case "python":
                    return "可代下载：官方免安装版（约 11 MB），解压即用，不写注册表。";
                case "ffmpeg":
                    return "可代下载：官方发行包（约 80~150 MB），解压后用它的 bin 目录，不装进系统。";
                case "wwise":
                    return "需要注册 Audiokinetic 账号后经 Wwise Launcher 安装，无法代下载。";
                case "binkdll":
                    return "商业 DLL，本项目不分发。脚本会自动读取你的《绝地潜兵 2》安装目录。";
            }
            return "";
        }

        private static string ZhState(DepInfo d)
        {
            if (d.Installed) return "已安装";
            return d.Auto ? "缺失" : "缺失(需手动)";
        }

        // ------------------------------------------------------------ actions

        private void RunCheck()
        {
            btnRefresh.Enabled = false;
            LogLine("$ deps.ps1 -Check -Lines");
            string[] rootOut = new string[2];
            List<string> lines = RunSync("-Check -Lines");
            deps = ParseDeps(lines.ToArray(), rootOut);
            depsRoot = rootOut[0] == null ? "" : rootOut[0];
            if (deps.Count == 0)
            {
                LogLine("没有解析到任何依赖信息。请确认 tools\\deps.ps1 存在且可运行。");
                foreach (string l in lines) LogLine(l);
            }
            else
            {
                lblRoot.Text = "下载目录：" + depsRoot + (rootOut[1] != null && rootOut[1].Length > 0 ? "    （已定位游戏：" + rootOut[1] + "）" : "");
                FillGrid();
                int missing = 0;
                foreach (DepInfo d in deps) if (!d.Installed) missing++;
                LogLine(missing == 0 ? "全部依赖已就绪。" : ("有 " + missing + " 项依赖缺失。"));
            }
            btnRefresh.Enabled = true;
        }

        private void FillGrid()
        {
            grid.Rows.Clear();
            foreach (DepInfo d in deps)
            {
                int idx = grid.Rows.Add();
                DataGridViewRow row = grid.Rows[idx];
                row.Cells["name"].Value = ZhName(d.Id);
                row.Cells["state"].Value = ZhState(d);
                if (d.Installed) row.Cells["state"].Style.ForeColor = Color.ForestGreen;
                else row.Cells["state"].Style.ForeColor = Color.Firebrick;
                row.Cells["pick"].Value = false;
                row.Cells["pick"].ReadOnly = !d.Auto || d.Installed;
                string url = d.Url;
                if (d.Sources.Length > 0) url = d.Sources[0];
                row.Cells["url"].Value = url.Length > 0 ? url : "（来自游戏本体，无需下载）";
                row.Cells["url"].ReadOnly = !d.Auto || url.Length == 0;
                row.Cells["reach"].Value = "";
                row.Tag = d;
            }
            if (grid.Rows.Count > 0) grid.Rows[0].Selected = true;
        }

        private void ShowDetail()
        {
            if (grid.SelectedRows.Count == 0) { lblDetail.Text = ""; return; }
            DepInfo d = grid.SelectedRows[0].Tag as DepInfo;
            if (d == null) { lblDetail.Text = ""; return; }
            string s = ZhCondition(d.Id);
            if (d.Installed && d.Path.Length > 0) s = s + "\r\n已找到：" + d.Path;
            lblDetail.Text = s + "\r\n" + ZhNote(d.Id, d.Path);
            ReflowDetail();
        }

        /// <summary>Logs one SRC| probe line and records it under its dependency id.</summary>
        private void ReportProbe(string line, Dictionary<string, List<string>> byId,
                                 ref int ok, ref int fail)
        {
            Dictionary<string, string> f = ParseFields(line);
            string id = Field(f, "id") ?? "";
            bool isOk = Field(f, "ok") == "1";
            bool isDownload = Field(f, "kind") == "download";
            string txt = (isOk ? "可达 " : "不可达 ") + (Field(f, "http") ?? "?")
                + " · " + (Field(f, "ms") ?? "?") + "ms";
            if (isOk) ok++; else fail++;
            LogLine("  [" + id + "] " + (isDownload ? "下载源 " : "官网   ") + txt
                + "  " + (Field(f, "url") ?? ""));
            if (!byId.ContainsKey(id)) byId[id] = new List<string>();
            byId[id].Add((isDownload ? "" : "官网 ") + txt);
        }

        /// <summary>Paints the reachability column from the recorded probe results.</summary>
        private void ApplyReachability(Dictionary<string, List<string>> byId)
        {
            foreach (DataGridViewRow row in grid.Rows)
            {
                DepInfo d = row.Tag as DepInfo;
                if (d == null || !byId.ContainsKey(d.Id)) continue;
                row.Cells["reach"].Value = byId[d.Id][0];
                bool any = false;
                foreach (string t in byId[d.Id])
                    if (IsReachable(t)) any = true;
                row.Cells["reach"].Style.ForeColor = any ? Color.ForestGreen : Color.Firebrick;
            }
        }

        private void RunTestSources()
        {
            btnTest.Enabled = false;
            LogLine("");
            LogLine("$ deps.ps1 -TestSources -Lines  （逐个探测下载源，可能要等十几秒）");
            List<string> lines = RunSync("-TestSources -Lines");
            int ok = 0, fail = 0;
            Dictionary<string, List<string>> byId = new Dictionary<string, List<string>>();
            foreach (string line in lines)
            {
                if (line.StartsWith("SRC|")) ReportProbe(line, byId, ref ok, ref fail);
            }
            ApplyReachability(byId);
            LogLine("探测完成：可达 " + ok + " 个，不可达 " + fail + " 个。");
            if (ok == 0 && fail > 0)
                LogLine("所有镜像都不可达。可以手动把「下载地址」改成你能访问的镜像（任意提供同名压缩包的地址）。");
            btnTest.Enabled = true;
        }

        private void RunDownload()
        {
            List<DepInfo> picked = new List<DepInfo>();
            List<string> urls = new List<string>();
            foreach (DataGridViewRow row in grid.Rows)
            {
                DepInfo d = row.Tag as DepInfo;
                if (d == null || !d.Auto || d.Installed) continue;
                object v = row.Cells["pick"].Value;
                if (v is bool && (bool)v)
                {
                    picked.Add(d);
                    object u = row.Cells["url"].Value;
                    urls.Add(u == null ? "" : u.ToString().Trim());
                }
            }
            if (picked.Count == 0)
            {
                MessageBox.Show(this, "请先勾选要下载的依赖。\r\n只有「缺失」且可代下载的项才能勾选。",
                    "未选择", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            StringBuilder list = new StringBuilder();
            StringBuilder srcMap = new StringBuilder();   // "id=url;id=url" - never json; see deps.ps1
            for (int i = 0; i < picked.Count; i++)
            {
                string u = urls[i];
                if (u.Length == 0) u = picked[i].Url;
                list.Append("  - " + ZhName(picked[i].Id) + "\r\n      " + u + "\r\n");
                if (i > 0) srcMap.Append(";");
                srcMap.Append(picked[i].Id + "=" + u);
            }

            string msg = "即将下载以下依赖：\r\n\r\n" + list.ToString()
                + "\r\n保存位置：" + depsRoot + "\r\n\r\n"
                + "下载来源为上述第三方官方发行地址，本程序只做下载与解压，不安装、不写系统目录、不改注册表。\r\n\r\n"
                + "确认开始下载吗？";
            if (MessageBox.Show(this, msg, "确认下载依赖", MessageBoxButtons.YesNo, MessageBoxIcon.Question)
                != DialogResult.Yes) return;

            StringBuilder which = new StringBuilder();
            for (int i = 0; i < picked.Count; i++)
            {
                if (i > 0) which.Append(",");
                which.Append(picked[i].Id);
            }

            // -Source carries "id=url;id=url" (no inner quotes), which survives the
            // Windows command line intact.
            string tail = "-Download -Which " + which.ToString() + " -Source \"" + srcMap.ToString() + "\"";
            StartStream(tail);
        }

        private void StartStream(string tail)
        {
            if (proc != null && !proc.HasExited) return;
            string arguments = PsArguments(tail);
            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", arguments);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            Encoding enc = MainForm.ConsoleEncoding();
            psi.StandardOutputEncoding = enc;
            psi.StandardErrorEncoding = enc;

            LogLine("");
            LogLine("$ " + arguments);
            LogLine("");

            try
            {
                proc = new Process();
                proc.StartInfo = psi;
                proc.EnableRaisingEvents = true;
                proc.OutputDataReceived += delegate(object s, DataReceivedEventArgs e)
                {
                    if (e.Data != null) LogLine(e.Data);
                };
                proc.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e)
                {
                    if (e.Data != null) LogLine(e.Data);
                };
                proc.Exited += delegate(object s, EventArgs e)
                {
                    int code = -1;
                    try { code = proc.ExitCode; } catch { }
                    BeginInvoke(new Action(delegate
                    {
                        btnDownload.Enabled = true;
                        btnTest.Enabled = true;
                        LogLine("");
                        LogLine(code == 0 ? "下载流程结束。请点「刷新」重新检测依赖。" : ("下载结束，退出码 " + code + "。"));
                        RunCheck();
                    }));
                };
                proc.Start();
                try { proc.StandardInput.Close(); } catch { }
                proc.BeginOutputReadLine();
                proc.BeginErrorReadLine();
                btnDownload.Enabled = false;
                btnTest.Enabled = false;
            }
            catch (Exception ex)
            {
                LogLine("[ERROR] 无法启动 PowerShell: " + ex.Message);
                btnDownload.Enabled = true;
                btnTest.Enabled = true;
            }
        }

        /// <summary>
        /// True when a probe line reports a reachable source. Kept as its own method because
        /// "不可达" contains "可达" as a substring, so the negative case must be excluded
        /// explicitly - and inlining that test pushed RunTestSources past the complexity gate.
        /// </summary>
        private static bool IsReachable(string text)
        {
            return text.IndexOf("可达") >= 0 && text.IndexOf("不可达") < 0;
        }

        private void LogLine(string line)
        {
            if (txtLog.InvokeRequired)
            {
                try { txtLog.BeginInvoke(new Action<string>(LogLine), line); } catch { }
                return;
            }
            txtLog.AppendText(line + "\r\n");
            txtLog.SelectionStart = txtLog.TextLength;
            txtLog.ScrollToCaret();
        }
    }
}
