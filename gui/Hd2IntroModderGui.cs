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

using System;
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

            lblStatus = new Label();
            lblStatus.Text = "就绪";
            lblStatus.Location = new Point(342, 210);
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
            }
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

        private static Encoding ConsoleEncoding()
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
                lblHint.Text = "把上面的日志内容发出来即可定位问题。详细日志也会留在 log\\ 目录里。";
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
}
