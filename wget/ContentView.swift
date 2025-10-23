//
//  ContentView.swift
//  wget
//
//  Created by Hoang Minh Khoi on 10/22/25.
//

import SwiftUI
internal import Combine

class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {

    static let shared = DownloadManager()
    
    @Published var progress: Double = 0
    @Published var status: String = "Idle"
    @Published var isDownloading = false
    
    private var session: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    private var resumeData: Data?
    
    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.khoi.wget.background")
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    
    func startDownload(from urlString: String) {
        guard let url = URL(string: urlString) else {
            status = "Invalid URL"
            return
        }
        status = "Starting download..."
        isDownloading = true
        
        if let resumeData = resumeData {
            // Resume from previous partial data
            downloadTask = session.downloadTask(withResumeData: resumeData)
        } else {
            // Start a new download
            let request = URLRequest(url: url)
            downloadTask = session.downloadTask(with: request)
        }
        downloadTask?.resume()
    }
    
    func pauseDownload() {
        guard isDownloading else { return }
        downloadTask?.cancel(byProducingResumeData: { data in
            self.resumeData = data
        })
        isDownloading = false
        status = "Paused"
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        resumeData = nil
        isDownloading = false
        progress = 0
        status = "Idle"
    }
    
    // MARK: - URLSession Delegate Methods
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async {
            self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            self.status = String(format: "Downloading... %.1f%%", self.progress * 100)
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        DispatchQueue.main.async {
            self.status = "Download complete"
            self.isDownloading = false
            self.progress = 1.0
        }
        
        // Move file to Documents directory
        let fileManager = FileManager.default
        let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destURL = docsURL.appendingPathComponent(downloadTask.originalRequest?.url?.lastPathComponent ?? "file.dat")
        
        try? fileManager.removeItem(at: destURL)
        do {
            try fileManager.moveItem(at: location, to: destURL)
            print("Saved to: \(destURL.path)")
        } catch {
            print("File move error:", error)
        }
        
        // Clear resume data after success
        resumeData = nil
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let err = error as NSError?, err.code != NSURLErrorCancelled {
            if let resumeData = err.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                self.resumeData = resumeData
                DispatchQueue.main.async {
                    self.status = "Interrupted — resumable"
                    self.isDownloading = false
                }
            } else {
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
    }
}

#Preview {
    ContentView()
}
