import Darwin
import Foundation
import RadarchikCore

// Root-часть «Защиты» Радарчика (SPEC §3б, этап 2).
//
// Запускает launchd от root (`/Library/LaunchDaemons/dev.kuzmenko.radarchik.guardd.plist`),
// работает всё время: держит таймеры автозакрытия. Умеет ровно пять вещей:
// открыть ключи (после Touch ID), закрыть ключи, подтвердить Touch ID просьбу
// к ssh-agent (файлы не трогая), отдать новые соединения с pktap («Сетевой надзор»),
// сказать свою версию. Ни git, ни shell, ни AppleScript здесь нет.
//
// Режимы:
//   (без аргументов)             служба launchd, слушает XPC от Радарчика;
//   --sniff <секунд>             напечатать исходящие соединения за N секунд (только root):
//                                проверить захват руками;
//   --release-all <user>         вернуть все ключи пользователю — перед удалением root-части (только root);
//   --release-excluded <user>    отдать пользователю то, что не секрет: файлы из исключений
//                                (лежат в git) и публичные ключи *.pub — при установке;
//   --version                    версия договора.

let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print(GuardHelper.version)
    exit(0)
}

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("Это root-часть Радарчика: её запускает launchd от root.\n".utf8))
    exit(1)
}

if let flag = arguments.firstIndex(of: "--release-all") {
    let user = arguments.dropFirst(flag + 1).first ?? ""
    exit(HelperEngine.releaseAll(userName: user))
}

if let flag = arguments.firstIndex(of: "--release-excluded") {
    let user = arguments.dropFirst(flag + 1).first ?? ""
    exit(HelperEngine.releaseExcluded(userName: user))
}

if let flag = arguments.firstIndex(of: "--sniff") {
    exit(NetworkSniffer.demo(seconds: Int(arguments.dropFirst(flag + 1).first ?? "") ?? 10))
}

let engine = HelperEngine()
engine.start()
// Делегат слушателя держим сами: у NSXPCListener ссылка на него слабая.
let delegate = ListenerDelegate(engine: engine)
let listener = NSXPCListener(machServiceName: GuardHelper.machService)
listener.delegate = delegate
listener.resume()
dispatchMain()
