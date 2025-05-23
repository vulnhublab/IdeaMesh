//
//  FileSync.swift
//  Ideamesh
//
//  Created by Mono Wang on 2/24/R4.
//

import Capacitor
import Foundation
import CryptoKit

// MARK: Global variable

// Defualts to dev
var URL_BASE = URL(string: "https://api-dev.ideamesh.khulnasoft.com/file-sync/")!
var BUCKET: String = "ideamesh-file-sync-bucket"
var REGION: String = "us-east-2"

var ENCRYPTION_SECRET_KEY: String?
var ENCRYPTION_PUBLIC_KEY: String?
var FNAME_ENCRYPTION_KEY: Data?

let FileSyncErrorDomain = "com.ideamesh.app.FileSyncErrorDomain"

// MARK: Helpers
@inline(__always) func fnameEncryptionEnabled() -> Bool {
    guard let _ = FNAME_ENCRYPTION_KEY else {
        return false
    }
    return true
}

// MARK: encryption helper

func maybeEncrypt(_ plaindata: Data) -> Data! {
    // avoid encryption twice
    if plaindata.starts(with: "-----BEGIN AGE ENCRYPTED FILE-----".data(using: .utf8)!) ||
        plaindata.starts(with: "age-encryption.org/v1\n".data(using: .utf8)!) {
        return plaindata
    }
    if let publicKey = ENCRYPTION_PUBLIC_KEY {
        // use armor = false, for smaller size
        if let cipherdata = AgeEncryption.encryptWithX25519(plaindata, publicKey, armor: false) {
            return cipherdata
        }
        return nil // encryption fail
    }
    return plaindata
}

func maybeDecrypt(_ cipherdata: Data) -> Data! {
    if let secretKey = ENCRYPTION_SECRET_KEY {
        if cipherdata.starts(with: "-----BEGIN AGE ENCRYPTED FILE-----".data(using: .utf8)!) ||
            cipherdata.starts(with: "age-encryption.org/v1\n".data(using: .utf8)!) {
            if let plaindata = AgeEncryption.decryptWithX25519(cipherdata, secretKey) {
                return plaindata
            }
            return nil
        }
        // not an encrypted file
        return cipherdata
    }
    return cipherdata
}

// MARK: Metadata type

public struct SyncMetadata: CustomStringConvertible, Equatable {
    var md5: String
    var size: Int
    var ctime: Int64
    var mtime: Int64

    public init?(of fileURL: URL) {
        do {
            let fileAttributes = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                                                                      .creationDateKey])
            guard fileAttributes.isRegularFile! else {
                return nil
            }
            size = fileAttributes.fileSize ?? 0
            mtime = Int64((fileAttributes.contentModificationDate?.timeIntervalSince1970 ?? 0.0) * 1000)
            ctime = Int64((fileAttributes.creationDate?.timeIntervalSince1970 ?? 0.0) * 1000)

            // incremental MD5 checksum
            let bufferSize = 512 * 1024
            let file = try FileHandle(forReadingFrom: fileURL)
            defer {
                file.closeFile()
            }
            var ctx = Insecure.MD5.init()
            while autoreleasepool(invoking: {
                let data = file.readData(ofLength: bufferSize)
                if data.count > 0 {
                    ctx.update(data: data)
                    return true // continue
                } else {
                    return false // eof
                }
            }) {}

            let computed = ctx.finalize()
            md5 = computed.map { String(format: "%02hhx", $0) }.joined()
        } catch {
            return nil
        }
    }

    public var description: String {
        return "SyncMetadata(md5=\(md5), size=\(size), mtime=\(mtime))"
    }
}

// MARK: FileSync Plugin

@objc(FileSyncPlugin)
public class FileSyncPlugin: CAPPlugin, SyncDebugDelegate {
    public var client: SyncClient!

    override public func load() {
        print("debug FileSync iOS plugin loaded!")

        client = SyncClient()
        client.delegate = self
    }

    // NOTE: for debug, or an activity indicator
    public func debugNotification(_ message: [String: Any]) {
        self.notifyListeners("debug", data: message)
    }

    @objc func keygen(_ call: CAPPluginCall) {
        let (secretKey, publicKey) = AgeEncryption.keygen()
        call.resolve(["secretKey": secretKey,
                      "publicKey": publicKey])
    }

    @objc func setKey(_ call: CAPPluginCall) {
        let secretKey = call.getString("secretKey")
        let publicKey = call.getString("publicKey")
        if secretKey == nil && publicKey == nil {
            ENCRYPTION_SECRET_KEY = nil
            ENCRYPTION_PUBLIC_KEY = nil
            FNAME_ENCRYPTION_KEY = nil
            return
        }
        guard let secretKey = secretKey, let publicKey = publicKey else {
            call.reject("both secretKey and publicKey should be provided")
            return
        }
        ENCRYPTION_SECRET_KEY = secretKey
        ENCRYPTION_PUBLIC_KEY = publicKey
        FNAME_ENCRYPTION_KEY = AgeEncryption.toRawX25519Key(secretKey)
    }

    @objc func setEnv(_ call: CAPPluginCall) {
        guard let env = call.getString("env") else {
            call.reject("required parameter: env")
            return
        }
        self.cancelAllRequests(call) // cancel all requests when setting new env
        self.setKey(call)

        switch env {
        case "production", "product", "prod":
            URL_BASE = URL(string: "https://api.ideamesh.khulnasoft.com/file-sync/")!
            BUCKET = "ideamesh-file-sync-bucket-prod"
            REGION = "us-east-1"
        case "development", "develop", "dev":
            URL_BASE = URL(string: "https://api-dev.ideamesh.khulnasoft.com/file-sync/")!
            BUCKET = "ideamesh-file-sync-bucket"
            REGION = "us-east-2"
        default:
            call.reject("invalid env: \(env)")
            return
        }

        self.debugNotification(["event": "setenv:\(env)"])
        call.resolve(["ok": true])
    }

    @objc func encryptFnames(_ call: CAPPluginCall) {
        guard fnameEncryptionEnabled() else {
            call.reject("fname encryption key not set")
            return
        }
        guard var fnames = call.getArray("filePaths") as? [String] else {
            call.reject("required parameters: filePaths")
            return
        }

        let nFiles = fnames.count
        fnames = fnames.compactMap { $0.fnameEncrypt(rawKey: FNAME_ENCRYPTION_KEY!) }
        if fnames.count != nFiles {
            call.reject("cannot encrypt \(nFiles - fnames.count) file names")
        }
        call.resolve(["value": fnames])
    }

    @objc func decryptFnames(_ call: CAPPluginCall) {
        guard fnameEncryptionEnabled() else {
            call.reject("fname encryption key not set")
            return
        }
        guard var fnames = call.getArray("filePaths") as? [String] else {
            call.reject("required parameters: filePaths")
            return
        }
        let nFiles = fnames.count
        fnames = fnames.compactMap { $0.fnameDecrypt(rawKey: FNAME_ENCRYPTION_KEY!) }
        if fnames.count != nFiles {
            call.reject("cannot decrypt \(nFiles - fnames.count) file names")
        }
        call.resolve(["value": fnames])
    }

    @objc func encryptWithPassphrase(_ call: CAPPluginCall) {
        guard let passphrase = call.getString("passphrase"),
              let content = call.getString("content") else {
            call.reject("required parameters: passphrase, content")
            return
        }
        guard let plaintext = content.data(using: .utf8) else {
            call.reject("cannot decode ciphertext with utf8")
            return
        }

        DispatchQueue.global(qos: .default).async {
            if let encrypted = AgeEncryption.encryptWithPassphrase(plaintext, passphrase, armor: true) {
                call.resolve(["data": String(data: encrypted, encoding: .utf8) as Any])
            } else {
                call.reject("cannot encrypt with passphrase")
            }
        }
    }

    @objc func decryptWithPassphrase(_ call: CAPPluginCall) {
        guard let passphrase = call.getString("passphrase"),
              let content = call.getString("content") else {
            call.reject("required parameters: passphrase, content")
            return
        }
        guard let ciphertext = content.data(using: .utf8) else {
            call.reject("cannot decode ciphertext with utf8")
            return
        }

        DispatchQueue.global(qos: .default).async {
            if let decrypted = AgeEncryption.decryptWithPassphrase(ciphertext, passphrase) {
                call.resolve(["data": String(data: decrypted, encoding: .utf8) as Any])
            } else {
                call.reject("cannot decrypt with passphrase")
            }
        }
    }

    @objc func getLocalFilesMeta(_ call: CAPPluginCall) {
        // filePaths are url encoded
        guard var basePath = call.getString("basePath"),
              let filePaths = call.getArray("filePaths") as? [String] else {
            call.reject("required paremeters: basePath, filePaths")
            return
        }
        basePath = basePath.replacingOccurrences(of: "file:///var/mobile/", with: "file:///private/var/mobile/")
        guard let baseURL = URL(string: basePath) else {
            call.reject("invalid basePath")
            return
        }

        DispatchQueue.global(qos: .default).async {
            var fileMetadataDict: [String: [String: Any]] = [:]
            for filePath in filePaths {
                let url = baseURL.appendingPathComponent(filePath)
                if let meta = SyncMetadata(of: url) {
                    var metaObj: [String: Any] = ["md5": meta.md5,
                                                  "size": meta.size,
                                                  "ctime": meta.ctime,
                                                  "mtime": meta.mtime]
                    metaObj["encryptedFname"] = filePath.fnameEncrypt(rawKey: FNAME_ENCRYPTION_KEY!)
                    fileMetadataDict[filePath] = metaObj
                }
            }
            call.resolve(["result": fileMetadataDict])
        }
    }

    @objc func getLocalAllFilesMeta(_ call: CAPPluginCall) {
        guard var basePath = call.getString("basePath"),
              let baseURL = URL(string: basePath) else {
            call.reject("invalid basePath")
            return
        }

        basePath = basePath.replacingOccurrences(of: "file:///var/mobile/", with: "file:///private/var/mobile/")

        DispatchQueue.global(qos: .default).async {
            var fileMetadataDict: [String: [String: Any]] = [:]
            if let enumerator = FileManager.default.enumerator(at: baseURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants, .skipsHiddenFiles]) {
                for case let fileURL as URL in enumerator {
                    if !fileURL.isSkipSync() {
                        if let meta = SyncMetadata(of: fileURL) {
                            let filePath = fileURL.relativePath(from: baseURL)!
                            // apply file name normalization
                            let normalizedFilePath = filePath.precomposedStringWithCanonicalMapping
                            if filePath != normalizedFilePath {
                                print("[warning] should rename files from \(filePath) to \(normalizedFilePath)")
                            }

                            var metaObj: [String: Any] = ["md5": meta.md5,
                                                          "size": meta.size,
                                                          "ctime": meta.ctime,
                                                          "mtime": meta.mtime]
                            metaObj["encryptedFname"] = normalizedFilePath.fnameEncrypt(rawKey: FNAME_ENCRYPTION_KEY!)
                            fileMetadataDict[normalizedFilePath] = metaObj
                        }
                    } else if fileURL.isICloudPlaceholder() {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                    }
                }
            }
            call.resolve(["result": fileMetadataDict])
        }
    }

    @objc func renameLocalFile(_ call: CAPPluginCall) {
        guard let basePath = call.getString("basePath"),
              let baseURL = URL(string: basePath) else {
            call.reject("invalid basePath")
            return
        }
        guard let from = call.getString("from") else {
            call.reject("invalid from file")
            return
        }
        guard let to = call.getString("to") else {
            call.reject("invalid to file")
            return
        }

        let fromUrl = baseURL.appendingPathComponent(from)
        let toUrl = baseURL.appendingPathComponent(to)

        do {
            try FileManager.default.moveItem(at: fromUrl, to: toUrl)
        } catch {
            call.reject("can not rename file: \(error.localizedDescription)")
            return
        }
        call.resolve(["ok": true])

    }

    @objc func deleteLocalFiles(_ call: CAPPluginCall) {
        guard let baseURL = call.getString("basePath").flatMap({path in URL(string: path)}),
              let filePaths = call.getArray("filePaths") as? [String] else {
            call.reject("required paremeters: basePath, filePaths")
            return
        }

        for filePath in filePaths {
            let fileUrl = baseURL.appendingPathComponent(filePath)
            try? FileManager.default.removeItem(at: fileUrl) // ignore any delete errors
        }
        call.resolve(["ok": true])
    }

    @objc func fetchRemoteFiles(_ call: CAPPluginCall) {
        guard let baseURL = call.getString("basePath").flatMap({path in URL(string: path)}),
              let filePaths = call.getArray("filePaths") as? [String],
              let graphUUID = call.getString("graphUUID"),
              let token = call.getString("token") else {
            call.reject("required paremeters: basePath, filePaths, graphUUID, token")
            return
        }

        // [encrypted-fname: original-fname]
        var encryptedFilePathDict: [String: String] = [:]
        for filePath in filePaths {
            if let encryptedPath = filePath.fnameEncrypt(rawKey: FNAME_ENCRYPTION_KEY!) {
                encryptedFilePathDict[encryptedPath] = filePath
            } else {
                call.reject("cannot decrypt all file names")
            }
        }

        let encryptedFilePaths = Array(encryptedFilePathDict.keys)

        var filesToBeMerged: [String] = []

        self.client.set(token: token, graphUUID: graphUUID)

        DispatchQueue.global(qos: .default).async {
            self.client.getFiles(at: encryptedFilePaths) { (fileURLs, error) in
                guard error == nil else {
                    print("debug getFiles error \(String(describing: error))")
                    self.debugNotification(["event": "download:error", "data": ["message": "error while getting files \(filePaths)"]])
                    call.reject(error!.localizedDescription)
                    return
                }
                // handle multiple completionHandlers
                let group = DispatchGroup()

                var downloaded: [String] = []

                for (encryptedFilePath, remoteFileURL) in fileURLs {
                    group.enter()

                    let filePath = encryptedFilePathDict[encryptedFilePath]!

                    var localFileURL: URL = baseURL.appendingPathComponent(filePath)
                    if localFileURL.pathExtension == "md" || localFileURL.pathExtension == "org" || localFileURL.pathExtension == "markdown" {
                        filesToBeMerged.append(filePath)
                        localFileURL = baseURL.appendingPathComponent("ideamesh/version-files/incoming").appendingPathComponent(filePath)
                    }

                    let progressHandler = {(progress: Progress) in
                        struct StaticHolder {
                            static var percent = 0
                        }
                        let percent = Int(progress.fractionCompleted * 100)
                        if percent / 5 != StaticHolder.percent / 5 {
                            StaticHolder.percent = percent
                            self.debugNotification(["event": "download:progress",
                                                    "data": ["file": filePath,
                                                             "graphUUID": graphUUID,
                                                             "type": "download",
                                                             "progress": progress.completedUnitCount,
                                                             "total": progress.totalUnitCount,
                                                             "percent": percent]])
                        }
                    }

                    self.client.download(url: remoteFileURL, progressHandler: progressHandler) {result in
                        switch result {
                        case .failure(let error):
                            self.debugNotification(["event": "download:error", "data": ["message": "error while downloading \(filePath): \(error)"]])
                            print("debug download \(error) in \(filePath)")
                        case .success(let tempURL):
                            self.debugNotification(["event": "download:progress",
                                                    "data": ["file": filePath,
                                                             "graphUUID": graphUUID,
                                                             "type": "download",
                                                             "percent": 100]])
                            do {
                                let rawData = try Data(contentsOf: tempURL!)
                                guard let decryptedRawData = maybeDecrypt(rawData) else {
                                    throw NSError(domain: FileSyncErrorDomain,
                                                  code: 0,
                                                  userInfo: [NSLocalizedDescriptionKey: "can not decrypt downloaded file"])
                                }
                                try localFileURL.writeData(data: decryptedRawData)
                                self.debugNotification(["event": "download:file", "data": ["file": filePath]])
                                downloaded.append(filePath)
                            } catch {
                                // Handle potential file system errors
                                self.debugNotification(["event": "download:error", "data": ["message": "error while downloading \(filePath): \(error)"]])
                                print("debug download \(error) in \(filePath)")
                            }
                        }

                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    self.debugNotification(["event": "download:done"])
                    call.resolve(["ok": true, "data": downloaded, "value": filesToBeMerged])
                }
            }
        }
    }

    /// remote -> local
    @objc func updateLocalFiles(_ call: CAPPluginCall) {
        guard let baseURL = call.getString("basePath").flatMap({path in URL(string: path)}),
              let filePaths = call.getArray("filePaths") as? [String],
              let graphUUID = call.getString("graphUUID"),
              let token = call.getString("token") else {
            call.reject("required paremeters: basePath, filePaths, graphUUID, token")
            return
        }

        // [encrypted-fname: original-fname]
        var encryptedFilePathDict: [String: String] = [:]
        if fnameEncryptionEnabled() {
            for filePath in filePaths {
                if let encryptedPath = filePath.fnameEncrypt(rawKey: FNAME_ENCRYPTION_KEY!) {
                    encryptedFilePathDict[encryptedPath] = filePath
                } else {
                    call.reject("cannot decrypt all file names")
                }
            }
        } else {
            encryptedFilePathDict = Dictionary(uniqueKeysWithValues: filePaths.map { ($0, $0) })
        }

        let encryptedFilePaths = Array(encryptedFilePathDict.keys)

        self.client.set(token: token, graphUUID: graphUUID)
        self.client.getFiles(at: encryptedFilePaths) { (fileURLs, error) in
            guard error == nil else {
                print("debug getFiles error \(String(describing: error))")
                self.debugNotification(["event": "download:error", "data": ["message": "error while getting files \(filePaths)"]])
                call.reject(error!.localizedDescription)
                return
            }
            // handle multiple completionHandlers
            let group = DispatchGroup()

            var downloaded: [String] = []

            for (encryptedFilePath, remoteFileURL) in fileURLs {
                group.enter()

                let filePath = encryptedFilePathDict[encryptedFilePath]!
                // NOTE: fileURLs from getFiles API is percent-encoded
                let localFileURL = baseURL.appendingPathComponent(filePath)

                let progressHandler = {(progress: Progress) in
                    struct StaticHolder {
                        static var percent = 0
                    }
                    let percent = Int(progress.fractionCompleted * 100)
                    if percent / 5 != StaticHolder.percent / 5 {
                        StaticHolder.percent = percent
                        self.debugNotification(["event": "download:progress",
                                                "data": ["file": filePath,
                                                         "graphUUID": graphUUID,
                                                         "type": "download",
                                                         "progress": progress.completedUnitCount,
                                                         "total": progress.totalUnitCount,
                                                         "percent": percent]])
                    }
                }

                self.client.download(url: remoteFileURL, progressHandler: progressHandler) {result in
                    switch result {
                    case .failure(let error):
                        self.debugNotification(["event": "download:error", "data": ["message": "error while downloading \(filePath): \(error)"]])
                        print("debug download \(error) in \(filePath)")
                    case .success(let tempURL):
                        do {
                            let rawData = try Data(contentsOf: tempURL!)
                            guard let decryptedRawData = maybeDecrypt(rawData) else {
                                throw NSError(domain: FileSyncErrorDomain,
                                              code: 0,
                                              userInfo: [NSLocalizedDescriptionKey: "can not decrypt downloaded file"])
                            }
                            try localFileURL.writeData(data: decryptedRawData)
                            self.debugNotification(["event": "download:file", "data": ["file": filePath]])
                            downloaded.append(filePath)
                        } catch {
                            // Handle potential file system errors
                            self.debugNotification(["event": "download:error", "data": ["message": "error while downloading \(filePath): \(error)"]])
                            print("debug download \(error) in \(filePath)")
                        }
                    }

                    group.leave()
                }
            }
            group.notify(queue: .main) {
                self.debugNotification(["event": "download:done"])
                call.resolve(["ok": true, "data": downloaded])
            }
        }
    }

    @objc func updateLocalVersionFiles(_ call: CAPPluginCall) {
        guard let baseURL = call.getString("basePath").flatMap({path in URL(string: path)}),
              let filePaths = call.getArray("filePaths") as? [String],
              let graphUUID = call.getString("graphUUID"),
              let token = call.getString("token") else {
            call.reject("required paremeters: basePath, filePaths, graphUUID, token")
            return
        }
        self.client.set(token: token, graphUUID: graphUUID)
        self.client.getVersionFiles(at: filePaths) {  (fileURLDict, error) in
            if let error = error {
                print("debug getVersionFiles error \(error)")
                call.reject(error.localizedDescription)
            } else {
                // handle multiple completionHandlers
                let group = DispatchGroup()

                var downloaded: [String] = []
                for (filePath, remoteFileURL) in fileURLDict {
                    group.enter()

                    // NOTE: fileURLs from getFiles API is percent-encoded
                    let localFileURL = baseURL.appendingPathComponent("ideamesh/version-files/").appendingPathComponent(filePath)
                    // empty progress handler
                    self.client.download(url: remoteFileURL, progressHandler: { _ in }) {result in
                        switch result {
                        case .failure(let error):
                            print("debug download \(error) in \(filePath)")
                        case .success(let tempURL):
                            do {
                                let rawData = try Data(contentsOf: tempURL!)
                                guard let decryptedRawData = maybeDecrypt(rawData) else {
                                    throw NSError(domain: FileSyncErrorDomain,
                                                  code: 0,
                                                  userInfo: [NSLocalizedDescriptionKey: "can not decrypt remote file"])
                                }
                                try localFileURL.writeData(data: decryptedRawData)
                                downloaded.append(filePath)
                            } catch {
                                print(error)
                            }
                        }
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    call.resolve(["ok": true, "data": downloaded])
                }

            }
        }
    }

    // filePaths: Encrypted file paths
    @objc func deleteRemoteFiles(_ call: CAPPluginCall) {
        guard let baseURL = call.getString("basePath").flatMap({path in URL(string: path)}),
              var filePaths = call.getArray("filePaths") as? [String],
              let graphUUID = call.getString("graphUUID"),
              let token = call.getString("token"),
              let txid = call.getInt("txid") else {
            call.reject("required paremeters: filePaths, graphUUID, token, txid")
            return
        }
        guard !filePaths.isEmpty else {
            call.reject("empty filePaths")
            return
        }

        let nFiles = filePaths.count
        if fnameEncryptionEnabled() {
            filePaths = filePaths.compactMap { $0.fnameEncrypt(rawKey: FNAME_ENCRYPTION_KEY!) }
        }
        if filePaths.count != nFiles {
            call.reject("cannot encrypt all file names")
        }

        client.set(token: token, graphUUID: graphUUID, txid: txid)
        client.deleteFiles(filePaths) { txid, error in
            guard error == nil else {
                call.reject("delete \(error!)")
                return
            }
            guard let txid = txid else {
                call.reject("missing txid")
                return
            }

            // delete all file
            for filePath in filePaths {
                let localFileURL = baseURL.appendingPathComponent("ideamesh/version-files/base").appendingPathComponent(filePath)
                do {
                    try FileManager.default.removeItem(at: localFileURL)
                } catch {
                    // sliently ignore
                    print("debug delete \(error) in \(filePath)")
                }
            }

            call.resolve(["ok": true, "txid": txid])
        }
    }

    /// local -> remote
    @objc func updateRemoteFiles(_ call: CAPPluginCall) {
        guard let baseURL = call.getString("basePath").flatMap({path in URL(string: path)}),
              let filePaths = call.getArray("filePaths") as? [String],
              let graphUUID = call.getString("graphUUID"),
              let token = call.getString("token"),
              let txid = call.getInt("txid") else {
            call.reject("required paremeters: basePath, filePaths, graphUUID, token, txid")
            return
        }
        let fnameEncryption = call.getBool("fnameEncryption") ?? false // default to false

        guard !filePaths.isEmpty else {
            return call.reject("empty filePaths")
        }

        self.client.set(token: token, graphUUID: graphUUID, txid: txid)

        // 1. refresh_temp_credential
        self.client.getTempCredential { (credentials, error) in
            guard error == nil else {
                self.debugNotification(["event": "upload:error", "data": ["message": "error while refreshing credential: \(error!)"]])
                call.reject("error(getTempCredential): \(error!)")
                return
            }

            var files: [String: URL] = [:]
            for filePath in filePaths {
                // NOTE: filePath from js may contain spaces
                let fileURL = baseURL.appendingPathComponent(filePath)
                files[filePath] = fileURL
            }

            // 2. upload_temp_file
            let progressHandler = {(filePath: String, progress: Progress) in
                struct StaticHolder {
                    static var percent = 0
                }
                let percent = Int(progress.fractionCompleted * 100)
                if percent / 5 != StaticHolder.percent / 5 {
                    StaticHolder.percent = percent
                    self.debugNotification(["event": "upload:progress",
                                            "data": ["file": filePath,
                                                     "graphUUID": graphUUID,
                                                     "type": "upload",
                                                     "progress": progress.completedUnitCount,
                                                     "total": progress.totalUnitCount,
                                                     "percent": percent]])
                }
            }
            self.client.uploadTempFiles(files, credentials: credentials!, progressHandler: progressHandler) { (uploadedFileKeyDict, fileMd5Dict, error) in
                guard error == nil else {
                    self.debugNotification(["event": "upload:error", "data": ["message": "error while uploading temp files: \(error!)"]])
                    call.reject("error(uploadTempFiles): \(error!)")
                    return
                }
                // 3. update_files
                guard !uploadedFileKeyDict.isEmpty else {
                    self.debugNotification(["event": "upload:error", "data": ["message": "no file to update"]])
                    call.reject("no file to update")
                    return
                }

                // encrypted-file-name: (file-key, md5)
                var uploadedFileKeyMd5Dict: [String: [String]] = [:]

                if fnameEncryptionEnabled() && fnameEncryption {
                    for (filePath, fileKey) in uploadedFileKeyDict {
                        guard let encryptedFilePath = filePath.fnameEncrypt(rawKey: FNAME_ENCRYPTION_KEY!) else {
                            call.reject("cannot encrypt file name")
                            return
                        }
                        uploadedFileKeyMd5Dict[encryptedFilePath] = [fileKey, fileMd5Dict[filePath]!]
                    }
                } else {
                    for (filePath, fileKey) in uploadedFileKeyDict {
                        uploadedFileKeyMd5Dict[filePath] = [fileKey, fileMd5Dict[filePath]!]
                    }
                }
                self.client.updateFiles(uploadedFileKeyMd5Dict) { (txid, error) in
                    guard error == nil else {
                        self.debugNotification(["event": "upload:error", "data": ["message": "error while updating files: \(error!)"]])
                        call.reject("error updateFiles: \(error!)")
                        return
                    }
                    guard let txid = txid else {
                        call.reject("error: missing txid")
                        return
                    }

                    for filePath in uploadedFileKeyDict.keys {
                        let from = files[filePath]!
                        if from.pathExtension == "md" || from.pathExtension == "org" || from.pathExtension == "markdown" {
                            let to = baseURL.appendingPathComponent("ideamesh/version-files/base").appendingPathComponent(filePath)
                            try? FileManager.default.removeItem(at: to)
                            to.ensureParentDir()
                            try? FileManager.default.copyItem(at: from, to: to)
                        }
                    }

                    self.debugNotification(["event": "upload:done", "data": ["files": filePaths, "txid": txid]])
                    call.resolve(["ok": true, "files": uploadedFileKeyDict, "txid": txid])
                }
            }
        }
    }

    @objc func cancelAllRequests(_ call: CAPPluginCall) {
        Task {
            _ = await client.cancelAllRequests()
            print("[debug] cancel all requres")
            call.resolve(["ok": true])
        }
    }

}
