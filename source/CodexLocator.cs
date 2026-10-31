using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Diagnostics;
public static class CodexLocator {
    public static string Find(string data) {
        var candidates=new List<string>();
        string preference=Path.Combine(data,"codex-path.txt");
        try { if(File.Exists(preference))candidates.Add(File.ReadAllText(preference).Trim()); } catch {}
        string local=Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        foreach(string root in new[]{Path.Combine(local,"OpenAI","Codex","bin"),Path.Combine(local,"Codex","bin")}) {
            try {if(Directory.Exists(root)) candidates.AddRange(Directory.GetDirectories(root).OrderByDescending(Directory.GetLastWriteTimeUtc).Select(d=>Path.Combine(d,"codex.exe")));} catch {}
            candidates.Add(Path.Combine(root,"codex.exe"));
        }
        foreach(string dir in (Environment.GetEnvironmentVariable("PATH")??"").Split(Path.PathSeparator)) {
            try { candidates.Add(Path.Combine(dir.Trim('"'),"codex.exe")); } catch {}
        }
        string npm=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),"npm","node_modules","@openai");
        foreach(string arch in new[]{"codex-win32-x64","codex"})
            candidates.Add(Path.Combine(npm,arch,"vendor","x86_64-pc-windows-msvc","codex","codex.exe"));
        return candidates.FirstOrDefault(p=>!string.IsNullOrWhiteSpace(p)&&Path.IsPathRooted(p)&&File.Exists(p));
    }
    public static string Require(string data) {
        string path=Find(data);
        if(path==null)throw new Exception("Установленный Codex не найден. Установите Codex или выберите codex.exe через меню «Путь к Codex…».");
        return path;
    }
    public static string Version(string path) {
        var info=new ProcessStartInfo(path,"--version"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
        using(var p=Process.Start(info)) {
            var output=p.StandardOutput.ReadToEndAsync();var errors=p.StandardError.ReadToEndAsync();
            if(!p.WaitForExit(10000)){try{p.Kill();}catch{}throw new Exception("Проверка Codex заняла больше 10 секунд.");}
            string text=output.GetAwaiter().GetResult().Trim();errors.GetAwaiter().GetResult();
            if(p.ExitCode!=0||!text.StartsWith("codex-cli "))throw new Exception("Этот файл не является работающим Codex CLI.");
            return text;
        }
    }
}
