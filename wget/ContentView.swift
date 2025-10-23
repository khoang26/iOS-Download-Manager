//
//  ContentView.swift
//  wget
//
//  Created by Hoang Minh Khoi on 10/22/25.
//

import SwiftUI
import Combine

class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    
    static let shared = DownloadManager()
    
    @Published var progress: Double = 0
    @Published var status: String = "Idle"
    @Published var isDownloading = false
    @Published var downloadedSize: Int64 = 0
    @Published var totalSize: Int64 = 0
    
    private var session: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    private var currentTaskIdentifier: Int?
    var resumeData: Data?
    private var fileURLString: String?
    
    private var backgroundCompletionHandler: (() -> Void)?
    
    private let resumeDataURL: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("resumeData.dat")
    }()
    
    let urlFile: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("downloadURL.txt")
    }()
    
    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.khoi.wget.background")
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        // Load persisted resumeData and URL
        if let data = try? Data(contentsOf: resumeDataURL) {
            self.resumeData = data
        }
        if let savedURL = try? String(contentsOf: urlFile, encoding: .utf8) {
            self.fileURLString = savedURL
            if resumeData != nil {
                status = "Ready to resume previous download"
            }
        }
    }
    
    // MARK: - Start / Resume
    func startDownload(from urlString: String) {
        // Prevent restarting active download
        if isDownloading { return }
        
        let url: URL
        if let saved = fileURLString, let resumeURL = URL(string: saved), resumeData != nil {
            url = resumeURL
        } else {
            guard let u = URL(string: urlString) else {
                status = "Invalid URL"
                return
            }
            url = u
            fileURLString = urlString
            try? urlString.write(to: urlFile, atomically: true, encoding: .utf8)
        }
        
        status = "Starting download..."
        isDownloading = true
        downloadedSize = 0
        totalSize = 0
        
        if let resumeData = resumeData {
            downloadTask = session.downloadTask(withResumeData: resumeData)
        } else {
            let request = URLRequest(url: url)
            downloadTask = session.downloadTask(with: request)
        }
        
        currentTaskIdentifier = downloadTask?.taskIdentifier
        downloadTask?.resume()
    }
    
    // MARK: - Pause
    func pauseDownload() {
        guard isDownloading else { return }
        downloadTask?.cancel(byProducingResumeData: { data in
            if let data = data {
                self.resumeData = data
                try? data.write(to: self.resumeDataURL)
            }
        })
        isDownloading = false
        status = "Paused"
    }
    
    // MARK: - Cancel
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        currentTaskIdentifier = nil
        resumeData = nil
        fileURLString = nil
        downloadedSize = 0
        totalSize = 0
        progress = 0
        isDownloading = false
        status = "Idle"
        
        try? FileManager.default.removeItem(at: resumeDataURL)
        try? FileManager.default.removeItem(at: urlFile)
    }
    
    // MARK: - Background session restoration
    func reconnectBackgroundSession(completionHandler: @escaping () -> Void) {
        let config = URLSessionConfiguration.background(withIdentifier: "com.khoi.wget.background")
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        backgroundCompletionHandler = completionHandler
        
        session.getAllTasks { tasks in
            if let task = tasks.first as? URLSessionDownloadTask {
                self.downloadTask = task
                self.currentTaskIdentifier = task.taskIdentifier
                DispatchQueue.main.async {
                    self.isDownloading = true
                    self.status = "Resuming download in background..."
                }
            }
        }
    }
    
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }
    
    // MARK: - URLSession Delegates
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        
        guard downloadTask.taskIdentifier == currentTaskIdentifier else { return }
        
        DispatchQueue.main.async {
            self.downloadedSize = totalBytesWritten
            self.totalSize = totalBytesExpectedToWrite
            self.progress = Double(totalBytesWritten) / Double(max(totalBytesExpectedToWrite,1))
            
            let downloadedMB = Double(totalBytesWritten) / 1_048_576
            let totalMB = Double(totalBytesExpectedToWrite) / 1_048_576
            self.status = String(format: "Downloading... %.1f%% (%.2f/%.2f MB)", self.progress*100, downloadedMB, totalMB)
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        
        guard downloadTask.taskIdentifier == currentTaskIdentifier else { return }
        
        DispatchQueue.main.async {
            self.status = "Download complete"
            self.isDownloading = false
            self.progress = 1.0
            self.downloadedSize = self.totalSize
        }
        
        let fileManager = FileManager.default
        let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destURL = docsURL.appendingPathComponent(downloadTask.originalRequest?.url?.lastPathComponent ?? "file.dat")
        
        try? fileManager.removeItem(at: destURL)
        do {
            try fileManager.moveItem(at: location, to: destURL)
            print("Saved to: \(destURL.path)")
        } catch {
            print("File move error:", error)
        }
        
        resumeData = nil
        fileURLString = nil
        currentTaskIdentifier = nil
        try? FileManager.default.removeItem(at: resumeDataURL)
        try? FileManager.default.removeItem(at: urlFile)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        
        guard task.taskIdentifier == currentTaskIdentifier else { return }
        
        if let err = error as NSError? {
            if let data = err.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                self.resumeData = data
                try? data.write(to: resumeDataURL)
                DispatchQueue.main.async {
                    self.status = "Interrupted — resumable"
                    self.isDownloading = false
                }
            } else if err.code != NSURLErrorCancelled {
                DispatchQueue.main.async {
                    self.status = "Error: \(err.localizedDescription)"
                    self.isDownloading = false
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var manager = DownloadManager.shared
    @State private var urlString: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("iOS Download Manager")
                .font(.headline)
            
            TextField("Enter file URL...", text: $urlString)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal)
                .disabled(manager.isDownloading || manager.resumeData != nil)
            
            ProgressView(value: manager.progress)
                .padding(.horizontal)
            
            Text(manager.status)
                .font(.subheadline)
            
            HStack(spacing: 15) {
                Button("Start / Resume") {
                    manager.startDownload(from: urlString)
                }
                .buttonStyle(.borderedProminent)
                
                Button("Pause") {
                    manager.pauseDownload()
                }
                .buttonStyle(.bordered)
                
                Button("Cancel") {
                    manager.cancelDownload()
                    urlString = ""
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .onAppear {
            // Restore URL for resumed download
            if let savedURL = try? String(contentsOf: manager.urlFile, encoding: .utf8) {
                urlString = savedURL
            }
        }
    }
}

#Preview {
    ContentView()
}
