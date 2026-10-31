using System;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Linq;
using System.Drawing;
using System.Windows.Forms;
using System.Diagnostics;
using System.Web.Script.Serialization;
using System.Collections.Generic;
using Microsoft.Win32;
class Setup : Form {
    const string UninstallKey="Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\CodexMeter";
    string data=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"CodexMeter");
    TextBox folder=new TextBox(),codex=new TextBox();
    Label status=new Label();
    CheckBox desktop=new CheckBox{Text="Создать ярлык на рабочем столе",Checked=true},startup=new CheckBox{Text="Запускать вместе с Windows",Checked=true},launch=new CheckBox{Text="Запустить после установки",Checked=true};
    Button install=new Button{Text="Установить"};
    public Setup() {
        Text="Установка CodexMeter 4.0 Lite";ClientSize=new Size(600,420);FormBorderStyle=FormBorderStyle.FixedDialog;MaximizeBox=false;StartPosition=FormStartPosition.CenterScreen;
        Icon=Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location);
        Font=new Font("Segoe UI",10);
        Controls.Add(new Label{Text="CodexMeter 4.0 Lite",Font=new Font("Segoe UI",19,FontStyle.Bold),Location=new Point(24,20),Size=new Size(540,42)});
        Controls.Add(new Label{Text="Все скины и размеры • иконка 67 • установленный Codex",Location=new Point(24,66),Size=new Size(550,25)});
        Controls.Add(new Label{Text="Папка установки (для текущего пользователя)",Location=new Point(24,104),Size=new Size(540,25)});
        folder.SetBounds(24,133,448,28);folder.Text=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Programs","CodexMeter");Controls.Add(folder);
        var browse=new Button{Text="Обзор…"};browse.SetBounds(480,132,96,29);browse.Click+=delegate{using(var d=new FolderBrowserDialog{SelectedPath=folder.Text})if(d.ShowDialog()==DialogResult.OK)folder.Text=d.SelectedPath;};Controls.Add(browse);
        Controls.Add(new Label{Text="Установленный Codex CLI",Location=new Point(24,179),Size=new Size(540,25)});
        codex.SetBounds(24,207,448,28);codex.Text=CodexLocator.Find(data)??"";Controls.Add(codex);
        var choose=new Button{Text="Выбрать…"};choose.SetBounds(480,207,96,29);choose.Click+=delegate{using(var d=new OpenFileDialog{Filter="Codex CLI|codex.exe"})if(d.ShowDialog()==DialogResult.OK)codex.Text=d.FileName;};Controls.Add(choose);
        status.SetBounds(24,244,550,39);status.Text=codex.Text.Length>0?"Codex найден. При установке будет проверен запуск CLI.":"Codex не найден. Установите Codex и повторите проверку либо выберите codex.exe.";Controls.Add(status);
        desktop.SetBounds(24,286,530,25);startup.SetBounds(24,314,530,25);launch.SetBounds(24,342,530,25);Controls.AddRange(new Control[]{desktop,startup,launch});
        install.SetBounds(366,380,110,30);install.Click+=Install;Controls.Add(install);AcceptButton=install;
        var cancel=new Button{Text="Отмена",DialogResult=DialogResult.Cancel};cancel.SetBounds(486,380,90,30);Controls.Add(cancel);CancelButton=cancel;
    }
    static string[] Files(){using(var z=new ZipArchive(Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"),ZipArchiveMode.Read))return z.Entries.Where(e=>!string.IsNullOrEmpty(e.Name)).Select(e=>e.FullName).ToArray();}
    static void Extract(string target) {
        string root=Path.GetFullPath(target).TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar;
        using(var z=new ZipArchive(Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"),ZipArchiveMode.Read))foreach(var e in z.Entries) {
            if(string.IsNullOrEmpty(e.Name))continue;
            string path=Path.GetFullPath(Path.Combine(root,e.FullName));
            if(!path.StartsWith(root,StringComparison.OrdinalIgnoreCase))throw new Exception("Некорректный путь внутри установщика.");
            Directory.CreateDirectory(Path.GetDirectoryName(path));e.ExtractToFile(path,true);
        }
    }
    static void Shortcut(string path,string target,string arguments="") {
        Type type=Type.GetTypeFromProgID("WScript.Shell");dynamic shell=Activator.CreateInstance(type);dynamic link=shell.CreateShortcut(path);
        link.TargetPath=target;link.Arguments=arguments;link.WorkingDirectory=Path.GetDirectoryName(target);link.IconLocation=target+",0";link.Save();
        System.Runtime.InteropServices.Marshal.FinalReleaseComObject(link);System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shell);
    }
    static bool Running(string target) {
        foreach(var p in Process.GetProcessesByName("CodexMeter"))using(p){try{if(string.Equals(p.MainModule.FileName,target,StringComparison.OrdinalIgnoreCase))return true;}catch{}}
        return false;
    }
    async void Install(object sender,EventArgs args) {
        install.Enabled=false;
        try {
            string cli=Path.GetFullPath(codex.Text.Trim()),target=Path.GetFullPath(folder.Text.Trim());
            if(Path.GetPathRoot(target).TrimEnd('\\')==target.TrimEnd('\\'))throw new Exception("Выберите отдельную папку приложения, а не корень диска.");
            string exe=Path.Combine(target,"CodexMeter.exe");
            if(Running(exe))throw new Exception("Закройте установленный CodexMeter через «Выход из приложения» и повторите установку.");
            status.Text="Проверка Codex…";
            string version=await System.Threading.Tasks.Task.Run(()=>CodexLocator.Version(cli));
            status.Text=version+" — установка…";
            // Stage first, so dependency and archive failures do not change user preferences.
            string stage=Path.Combine(Path.GetTempPath(),"CodexMeterSetup-"+Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(stage);Extract(stage);
            Directory.CreateDirectory(target);
            foreach(string name in Files()){string destination=Path.Combine(target,name);Directory.CreateDirectory(Path.GetDirectoryName(destination));File.Copy(Path.Combine(stage,name),destination,true);}
            // Retire only superseded built-in PNG assets after their WebP replacements are installed.
            foreach(string old in new[]{"analog.png","beskar.png","blue.png","counterstrike.png","diablo.png","doom2.png","fallout.png","green.png","heroes3.png","imperial.png","pilot.png","starcraft.png","terminator2.png","vicecity.png"}){string png=Path.Combine(target,"skins",old),webp=Path.ChangeExtension(png,".webp");if(File.Exists(webp)&&File.Exists(png))File.Delete(png);}
            if(File.Exists(Path.Combine(target,"icon-67-512.webp"))&&File.Exists(Path.Combine(target,"icon-67.png")))File.Delete(Path.Combine(target,"icon-67.png"));
            File.Copy(Assembly.GetExecutingAssembly().Location,Path.Combine(target,"Uninstall.exe"),true);
            Directory.CreateDirectory(data);File.WriteAllText(Path.Combine(data,"codex-path.txt"),cli);
            string settingsFile=Path.Combine(data,"settings.json");var json=new JavaScriptSerializer();var settings=new Dictionary<string,object>();
            if(File.Exists(settingsFile))settings=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(settingsFile));
            settings["startupEnabled"]=startup.Checked;File.WriteAllText(settingsFile,json.Serialize(settings));
            using(var run=Registry.CurrentUser.CreateSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Run")){if(startup.Checked)run.SetValue("CodexMeter","\""+exe+"\" --startup");else run.DeleteValue("CodexMeter",false);}
            string menu=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs),"CodexMeter");Directory.CreateDirectory(menu);
            Shortcut(Path.Combine(menu,"CodexMeter.lnk"),exe);Shortcut(Path.Combine(menu,"Удалить CodexMeter.lnk"),Path.Combine(target,"Uninstall.exe"),"--uninstall");
            string desk=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),"CodexMeter.lnk");if(desktop.Checked)Shortcut(desk,exe);else if(File.Exists(desk))File.Delete(desk);
            using(var key=Registry.CurrentUser.CreateSubKey(UninstallKey)){
                key.SetValue("DisplayName","CodexMeter Lite");key.SetValue("DisplayVersion","4.0");key.SetValue("Publisher","CodexMeter");key.SetValue("InstallLocation",target);
                key.SetValue("DisplayIcon",exe+",0");key.SetValue("UninstallString","\""+Path.Combine(target,"Uninstall.exe")+"\" --uninstall");key.SetValue("NoModify",1);key.SetValue("NoRepair",1);
            }
            foreach(string name in Files())File.Delete(Path.Combine(stage,name));
            foreach(string dir in Directory.GetDirectories(stage).OrderByDescending(d=>d.Length))if(!Directory.EnumerateFileSystemEntries(dir).Any())Directory.Delete(dir);
            if(!Directory.EnumerateFileSystemEntries(stage).Any())Directory.Delete(stage);
            MessageBox.Show(this,"CodexMeter установлен. При первом запуске войдите в свой ChatGPT через меню приложения.","Готово",MessageBoxButtons.OK,MessageBoxIcon.Information);
            if(launch.Checked)Process.Start(exe);Close();
        }catch(Exception e){status.Text="Установка не завершена.";MessageBox.Show(this,e.Message,"Установка",MessageBoxButtons.OK,MessageBoxIcon.Warning);install.Enabled=true;}
    }
    static void Uninstall() {
        string root=AppDomain.CurrentDomain.BaseDirectory,exe=Path.Combine(root,"CodexMeter.exe");
        using(var key=Registry.CurrentUser.OpenSubKey(UninstallKey)) {
            if(key==null||!string.Equals(Path.GetFullPath(Convert.ToString(key.GetValue("InstallLocation"))).TrimEnd('\\'),root.TrimEnd('\\'),StringComparison.OrdinalIgnoreCase))throw new Exception("Папка установки не подтверждена. Удаление отменено.");
        }
        if(Running(exe))throw new Exception("Сначала закройте CodexMeter через «Выход из приложения».");
        if(MessageBox.Show("Удалить CodexMeter? Настройки и вход сохранятся.","Удаление",MessageBoxButtons.YesNo,MessageBoxIcon.Question)!=DialogResult.Yes)return;
        foreach(string name in Files()) {string path=Path.GetFullPath(Path.Combine(root,name));if(!path.StartsWith(root,StringComparison.OrdinalIgnoreCase))throw new Exception("Некорректный путь удаления.");if(File.Exists(path))File.Delete(path);}
        foreach(string name in new[]{"skins"}){string path=Path.Combine(root,name);if(Directory.Exists(path)&&!Directory.EnumerateFileSystemEntries(path).Any())Directory.Delete(path);}
        using(var run=Registry.CurrentUser.OpenSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Run",true)){if(run!=null&&Convert.ToString(run.GetValue("CodexMeter")).Contains(exe))run.DeleteValue("CodexMeter",false);}
        string desk=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),"CodexMeter.lnk");if(File.Exists(desk))File.Delete(desk);
        string menu=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs),"CodexMeter");foreach(string name in new[]{"CodexMeter.lnk","Удалить CodexMeter.lnk"}){string path=Path.Combine(menu,name);if(File.Exists(path))File.Delete(path);}if(Directory.Exists(menu)&&!Directory.EnumerateFileSystemEntries(menu).Any())Directory.Delete(menu);
        Registry.CurrentUser.DeleteSubKeyTree(UninstallKey,false);
        MessageBox.Show("CodexMeter удалён. После закрытия этого окна можно удалить оставшийся файл Uninstall.exe и папку приложения.","Готово");
    }
    [STAThread] static int Main(string[] args) {
        Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
        try {
            if(args.Contains("--preview")){using(var form=new Setup()){form.Show();Application.DoEvents();using(var bitmap=new Bitmap(form.Width,form.Height)){form.DrawToBitmap(bitmap,new Rectangle(0,0,form.Width,form.Height));bitmap.Save(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"installer-preview.png"));}}return 0;}
            if(args.Contains("--self-test")){
                string target=Path.Combine(Path.GetTempPath(),"CodexMeterPayload-"+Guid.NewGuid().ToString("N"));Extract(target);
                if(!File.Exists(Path.Combine(target,"CodexMeter.exe"))||Directory.Exists(Path.Combine(target,"runtime"))||!File.Exists(Path.Combine(target,"skins","skins.json")))throw new Exception("Payload check failed");
                Shortcut(Path.Combine(target,"test.lnk"),Path.Combine(target,"CodexMeter.exe"));if(!File.Exists(Path.Combine(target,"test.lnk")))throw new Exception("Shortcut check failed");
                string cli=CodexLocator.Require(Path.Combine(target,"profile"));string version=CodexLocator.Version(cli);
                var info=new ProcessStartInfo(Path.Combine(target,"CodexMeter.exe"),"--self-test"){UseShellExecute=false,CreateNoWindow=true};using(var p=Process.Start(info)){p.WaitForExit();if(p.ExitCode!=0)throw new Exception("Application check failed");}
                File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"installer-test.txt"),"PASS: safe embedded payload extraction, installed Codex discovery: "+version+", application self-test, isolated Windows shortcut creation. No registry, shortcuts, user profile or model calls changed.");return 0;
            }
            if(args.Contains("--uninstall"))Uninstall();else Application.Run(new Setup());return 0;
        }catch(Exception e){if(args.Contains("--self-test"))File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"installer-error.txt"),e.ToString());else MessageBox.Show(e.Message,"CodexMeter");return 1;}
    }
}
