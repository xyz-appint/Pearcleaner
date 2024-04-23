//
//  AppPathsFetch-NEW.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 4/4/24.
//

import Foundation
import AppKit
import SwiftUI


class AppPathFinder {
    private var appInfo: AppInfo
    private var appState: AppState
    private var locations: Locations
    private var backgroundRun: Bool
    private var reverseAddon: Bool
    private var completion: () -> Void = {}
    private var collection: [URL] = []
    private let collectionAccessQueue = DispatchQueue(label: "com.alienator88.Pearcleaner.appPathFinder.collectionAccess")

    init(appInfo: AppInfo = .empty, appState: AppState, locations: Locations, backgroundRun: Bool = false, reverseAddon: Bool = false, completion: @escaping () -> Void = {}) {
        self.appInfo = appInfo
        self.appState = appState
        self.locations = locations
        self.backgroundRun = backgroundRun
        self.reverseAddon = reverseAddon
        self.completion = completion
    }

    func findPaths() {
        Task(priority: .background) {
            self.initialURLProcessing()
            self.collectDirectories()
            self.collectFiles()
            self.finalizeCollection()
        }
    }

    private func initialURLProcessing() {
        if let url = URL(string: self.appInfo.path.absoluteString), !url.path.contains(".Trash") {
            let modifiedUrl = url.path.contains("Wrapper") ? url.deletingLastPathComponent().deletingLastPathComponent() : url
            self.collection.append(modifiedUrl)
        }
    }

    private func collectDirectories() {
        let dispatchGroup = DispatchGroup()

        for location in self.locations.apps.paths {
            dispatchGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                self.processDirectoryLocation(location)
                dispatchGroup.leave()
            }
        }

        dispatchGroup.wait()
    }

    private func processDirectoryLocation(_ location: String) {
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: location) {
            for item in contents {
                let itemURL = URL(fileURLWithPath: location).appendingPathComponent(item)
                let itemL = item.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "").lowercased()

                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    // Perform the check to skip the item if needed
                    if shouldSkipItem(itemL, at: itemURL) {
                        continue
                    }

                    collectionAccessQueue.sync {
                        let alreadyIncluded = self.collection.contains { existingURL in
                            itemURL.path.hasPrefix(existingURL.path)
                        }

                        if !alreadyIncluded && specificCondition(itemL: itemL, itemURL: itemURL) {
                            self.collection.append(itemURL)
                        }
                    }
                }
            }
        }
    }

    private func collectFiles() {
        let dispatchGroup = DispatchGroup()

        for location in self.locations.apps.paths {
            dispatchGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                self.processFileLocation(location)
                dispatchGroup.leave()
            }
        }

        dispatchGroup.wait()
    }

    private func processFileLocation(_ location: String) {
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: location) {
            for item in contents {
                let itemURL = URL(fileURLWithPath: location).appendingPathComponent(item)
                let itemL = item.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "").lowercased()

                if FileManager.default.fileExists(atPath: itemURL.path),
                   !shouldSkipItem(itemL, at: itemURL),
                   specificCondition(itemL: itemL, itemURL: itemURL) {
                    collectionAccessQueue.sync {
                        self.collection.append(itemURL)
                    }
                }
            }
        }
    }



    private func shouldSkipItem(_ itemL: String, at itemURL: URL) -> Bool {
        var containsItem = false
        collectionAccessQueue.sync {
            containsItem = self.collection.contains(itemURL)
        }
        if containsItem || !isSupportedFileType(at: itemURL.path) {
            return true
        }

        for skipCondition in skipConditions {
            if itemL.hasPrefix(skipCondition.skipPrefix) {
                let isAllowed = skipCondition.allowPrefixes.contains(where: itemL.hasPrefix)
                if !isAllowed {
                    return true // Skip because it starts with a base prefix but is not in the allowed list
                }
            }
        }

        return false
    }



    private func specificCondition(itemL: String, itemURL: URL) -> Bool {
        let bundleIdentifierL = self.appInfo.bundleIdentifier.pearFormat()
        let bundleComponents = self.appInfo.bundleIdentifier.components(separatedBy: ".").compactMap { $0 != "-" ? $0.lowercased() : nil }
        let bundle = bundleComponents.suffix(2).joined()
        let nameL = self.appInfo.appName.pearFormat()
        let nameP = self.appInfo.path.lastPathComponent.replacingOccurrences(of: ".app", with: "")

        for condition in conditions {
            if bundleIdentifierL.contains(condition.bundle_id) {
                // Exclude and include keywords
                let hasIncludeKeyword = condition.include.contains(where: itemL.contains)
                let hasExcludeKeyword = condition.exclude.contains(where: itemL.contains)

                if hasExcludeKeyword {
                    return false
                }
                if hasIncludeKeyword {
                    if !condition.exclude.contains(where: itemL.contains) {
                        return true
                    }
                }
            }
        }


        if self.appInfo.webApp {
            return itemL.contains(bundleIdentifierL)
        }

        return itemL.contains(bundleIdentifierL) || itemL.contains(bundle) || (nameL.count > 3 && itemL.contains(nameL)) || (nameP.count > 3 && itemL.contains(nameP))

    }


    private func getAllContainers(bundleURL: URL) -> [URL] {
        var containers = [URL]()

        // Extract bundle identifier from bundleURL
        let bundleIdentifier = Bundle(url: bundleURL)?.bundleIdentifier

        // Ensure the bundleIdentifier is not nil
        guard let containerBundleIdentifier = bundleIdentifier else {
            printOS("Get Containers: No bundle identifier found for the given bundle URL.")
            return containers  // Returns whatever was found so far, possibly empty
        }

        // Get the regular container URL for the extracted bundle identifier
        if let groupContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: containerBundleIdentifier) {
            containers.append(groupContainer)
        } else {
            printOS("Get Containers: Failed to retrieve container URL for bundle identifier: \(containerBundleIdentifier)")
        }

        let containersPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("Containers")

        do {
            let containerDirectories = try FileManager.default.contentsOfDirectory(at: containersPath!, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)

            // Define a regular expression to match UUID format
            let uuidRegex = try NSRegularExpression(pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$", options: .caseInsensitive)

            for directory in containerDirectories {
                let directoryName = directory.lastPathComponent

                // Check if the directory name matches the UUID pattern
                if uuidRegex.firstMatch(in: directoryName, options: [], range: NSRange(location: 0, length: directoryName.utf16.count)) != nil {
                    // Attempt to read the metadata plist file
                    let metadataPlistURL = directory.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
                    if let metadataDict = NSDictionary(contentsOf: metadataPlistURL), let applicationBundleID = metadataDict["MCMMetadataIdentifier"] as? String {
                        if applicationBundleID == self.appInfo.bundleIdentifier {
                            containers.append(directory)
                        }
                    }
                }
            }
        } catch {
            printOS("Error accessing the Containers directory: \(error)")
        }


//        let fileURL = URL(fileURLWithPath: "/Users/alin/Library/Containers/2792352D-95FE-43AE-947D-FF4BF31DE4E6")
//
//        do {
//            // Retrieve the localized name
//            let resourceValues = try fileURL.resourceValues(forKeys: [.localizedNameKey])
//            if let localizedName = resourceValues.localizedName {
//                print("Localized Name: \(localizedName)")
//            } else {
//                print("Localized name not available.")
//            }
//        } catch {
//            print("Error retrieving localized name: \(error)")
//        }



        // Return all found containers
        return containers
    }


    private func handleOutliers() -> [URL] {
        var outliers: [URL] = []
        let bundleIdentifier = self.appInfo.bundleIdentifier.pearFormat()

        // Find conditions that match the current app's bundle identifier
        let matchingConditions = conditions.filter { condition in
            bundleIdentifier.contains(condition.bundle_id)
        }

        for condition in matchingConditions {
            if let forceIncludes = condition.includeForce {
                for path in forceIncludes {
                    if let url = URL(string: path), FileManager.default.fileExists(atPath: url.path) {
                        outliers.append(url)
                    }
                }
            }
        }

        return outliers
    }

    private func finalizeCollection() {
        DispatchQueue.global(qos: .userInitiated).async {
            let allContainers = self.getAllContainers(bundleURL: self.appInfo.path)
            let outliers = self.handleOutliers()
            var tempCollection: [URL] = []
            self.collectionAccessQueue.sync {
                tempCollection = self.collection
            }
            tempCollection.append(contentsOf: allContainers)
            tempCollection.append(contentsOf: outliers)

            // Sort and standardize URLs to ensure consistent comparisons
            let sortedCollection = tempCollection.map { $0.standardizedFileURL }.sorted(by: { $0.path < $1.path })
            var filteredCollection: [URL] = []
            var previousUrl: URL?
            for url in sortedCollection {
                if let previousUrl = previousUrl, url.path.hasPrefix(previousUrl.path + "/") {
                    // Current URL is a subdirectory of the previous one, so skip it
                    continue
                }
                // This URL is not a subdirectory of the previous one, so keep it and set it as the previous URL
                filteredCollection.append(url)
                previousUrl = url
            }

            self.handlePostProcessing(sortedCollection: filteredCollection)
        }

    }

    private func handlePostProcessing(sortedCollection: [URL]) {
        // Calculate file details (sizes and icons), update app state, and call completion
        var fileSize: [URL: Int64] = [:]
        var fileSizeLogical: [URL: Int64] = [:]
        var fileIcon: [URL: NSImage?] = [:]

        for path in sortedCollection {
            let size = totalSizeOnDisk(for: path)
            fileSize[path] = size.real
            fileSizeLogical[path] = size.logical
            fileIcon[path] = getIconForFileOrFolderNS(atPath: path)
        }

        DispatchQueue.main.async {
            var updatedCollection = sortedCollection
            if updatedCollection.count == 1, let firstURL = updatedCollection.first, firstURL.path.contains(".Trash") {
                updatedCollection.removeAll()
            }

            // Update appInfo and appState with the new values
            self.appInfo.fileSize = fileSize
            self.appInfo.fileSizeLogical = fileSizeLogical
            self.appInfo.fileIcon = fileIcon

            if !self.backgroundRun {
                self.appState.appInfo = self.appInfo
                self.appState.selectedItems = Set(updatedCollection)
            }

            // Append object to store if running reverse search with empty store
            if self.reverseAddon {
                self.appState.appInfoStore.append(self.appInfo)
            }

            self.completion()
        }
    }
}








// Async Test
//class AppPathFinder {
//    private var appInfo: AppInfo
//    private var appState: AppState
//    private var locations: Locations
//    private var backgroundRun: Bool
//    private var reverseAddon: Bool
//    private var completion: () -> Void = {}
//    private var collection: [URL] = []
//    private let collectionAccessQueue = DispatchQueue(label: "com.alienator88.Pearcleaner.appPathFinder.collectionAccess")
//    private var state = PathFinderState() // Actor instance
//
//    init(appInfo: AppInfo = .empty, appState: AppState, locations: Locations, backgroundRun: Bool = false, reverseAddon: Bool = false, completion: @escaping () -> Void = {}) {
//        self.appInfo = appInfo
//        self.appState = appState
//        self.locations = locations
//        self.backgroundRun = backgroundRun
//        self.reverseAddon = reverseAddon
//        self.completion = completion
//    }
//
//    func findPaths() async {
//        await initialURLProcessing()
//        await collectDirectories()
//        await collectFiles()
//        await finalizeCollection()
//    }
//
//    private func initialURLProcessing() async {
//        if let url = URL(string: self.appInfo.path.absoluteString), !url.path.contains(".Trash") {
//            let modifiedUrl = url.path.contains("Wrapper") ? url.deletingLastPathComponent().deletingLastPathComponent() : url
//            collectionAccessQueue.sync {
//                self.collection.append(modifiedUrl)
//            }
//        }
//    }
//
//    private func collectDirectories() async {
//        for location in self.locations.apps.paths {
//            await processDirectoryLocation(location)
//        }
//    }
//
//    private func processDirectoryLocation(_ location: String) async {
//        do {
//            let contents = try FileManager.default.contentsOfDirectory(atPath: location)
//            for item in contents {
//                let itemURL = URL(fileURLWithPath: location).appendingPathComponent(item)
//                let itemL = item.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "").lowercased()
//
//                var isDirectory: ObjCBool = false
//                if FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
//                    // Perform the check to skip the item if needed
//                    if shouldSkipItem(itemL, at: itemURL) {
//                        continue
//                    }
//
//                    collectionAccessQueue.sync {
//                        let alreadyIncluded = self.collection.contains { existingURL in
//                            itemURL.path.hasPrefix(existingURL.path)
//                        }
//
//                        if !alreadyIncluded && specificCondition(itemL: itemL, itemURL: itemURL) {
//                            self.collection.append(itemURL)
//                        }
//                    }
//                }
//            }
//        } catch {
//            print("Error processing directory location: \(location), error: \(error)")
//        }
//    }
//
//    private func collectFiles() async {
//        for location in self.locations.apps.paths {
//            await processFileLocation(location)
//        }
//    }
//
//    private func processFileLocation(_ location: String) async {
//        do {
//            let contents = try FileManager.default.contentsOfDirectory(atPath: location)
//            for item in contents {
//                let itemURL = URL(fileURLWithPath: location).appendingPathComponent(item)
//                let itemL = item.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "").lowercased()
//
//                if FileManager.default.fileExists(atPath: itemURL.path),
//                   !shouldSkipItem(itemL, at: itemURL),
//                   specificCondition(itemL: itemL, itemURL: itemURL) {
//                    collectionAccessQueue.sync {
//                        self.collection.append(itemURL)
//                    }
//                }
//            }
//        } catch {
//            print("Error processing file location: \(location), error: \(error)")
//        }
//    }
//
//
//
//    private func shouldSkipItem(_ itemL: String, at itemURL: URL) -> Bool {
//        var containsItem = false
//        collectionAccessQueue.sync {
//            containsItem = self.collection.contains(itemURL)
//        }
//        if containsItem || !isSupportedFileType(at: itemURL.path) {
//            return true
//        }
//
//        for skipCondition in skipConditions {
//            if itemL.hasPrefix(skipCondition.skipPrefix) {
//                let isAllowed = skipCondition.allowPrefixes.contains(where: itemL.hasPrefix)
//                if !isAllowed {
//                    return true // Skip because it starts with a base prefix but is not in the allowed list
//                }
//            }
//        }
//
//        return false
//    }
//
//
//
//    private func specificCondition(itemL: String, itemURL: URL) -> Bool {
//        let bundleIdentifierL = self.appInfo.bundleIdentifier.pearFormat()
//        let bundleComponents = self.appInfo.bundleIdentifier.components(separatedBy: ".").compactMap { $0 != "-" ? $0.lowercased() : nil }
//        let bundle = bundleComponents.suffix(2).joined()
//        let nameL = self.appInfo.appName.pearFormat()
//        let nameP = self.appInfo.path.lastPathComponent.replacingOccurrences(of: ".app", with: "")
//
//        for condition in conditions {
//            if bundleIdentifierL.contains(condition.bundle_id) {
//                // Exclude and include keywords
//                let hasIncludeKeyword = condition.include.contains(where: itemL.contains)
//                let hasExcludeKeyword = condition.exclude.contains(where: itemL.contains)
//
//                if hasExcludeKeyword {
//                    return false
//                }
//                if hasIncludeKeyword {
//                    if !condition.exclude.contains(where: itemL.contains) {
//                        return true
//                    }
//                }
//            }
//        }
//
//
//        if self.appInfo.webApp {
//            return itemL.contains(bundleIdentifierL)
//        }
//
//        return itemL.contains(bundleIdentifierL) || itemL.contains(bundle) || (nameL.count > 3 && itemL.contains(nameL)) || (nameP.count > 3 && itemL.contains(nameP))
//
//    }
//
//
//    func getGroupContainers(bundleURL: URL) async -> [URL] {
//        await withCheckedContinuation { continuation in
//            var groupContainers: [URL] = []
//            // Assume creating a SecStaticCode is synchronous and quick.
//            var staticCode: SecStaticCode?
//            let status = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
//
//            if status == errSecSuccess, let staticCode = staticCode {
//                var signingInformation: CFDictionary?
//
//                // This may involve a blocking call to fetch signing information.
//                let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(), &signingInformation)
//
//                if status == errSecSuccess, let infoDict = signingInformation as? [String: Any],
//                   let entitlementsDict = infoDict["entitlements-dict"] as? [String: Any],
//                   let appGroups = entitlementsDict["com.apple.security.application-groups"] as? [String] {
//
//                    let fileManager = FileManager.default
//                    let home = NSHomeDirectory()  // Assuming `home` is derived earlier or statically known.
//
//                    for groupID in appGroups {
//                        let groupURL = URL(fileURLWithPath: "\(home)/Library/Group Containers/\(groupID)")
//                        if fileManager.fileExists(atPath: groupURL.path) {
//                            groupContainers.append(groupURL)
//                        }
//                    }
//                }
//            }
//
//            // Continue once all operations are complete.
//            continuation.resume(returning: groupContainers)
//        }
//    }
//
//
//    private func handleOutliers() -> [URL] {
//        var outliers: [URL] = []
//        let bundleIdentifier = self.appInfo.bundleIdentifier.pearFormat()
//
//        // Find conditions that match the current app's bundle identifier
//        let matchingConditions = conditions.filter { condition in
//            bundleIdentifier.contains(condition.bundle_id)
//        }
//
//        for condition in matchingConditions {
//            if let forceIncludes = condition.includeForce {
//                for path in forceIncludes {
//                    if let url = URL(string: path), FileManager.default.fileExists(atPath: url.path) {
//                        outliers.append(url)
//                    }
//                }
//            }
//        }
//
//        return outliers
//    }
//
//    private func finalizeCollection() async {
//        let groupContainers = await getGroupContainers(bundleURL: self.appInfo.path)
//        let outliers = handleOutliers()
//        var tempCollection: [URL] = []
//
//        collectionAccessQueue.sync {
//            tempCollection = self.collection
//        }
//
//        tempCollection.append(contentsOf: groupContainers)
//        tempCollection.append(contentsOf: outliers)
//
//        // Sort and standardize URLs to ensure consistent comparisons
//        let sortedCollection = tempCollection.map { $0.standardizedFileURL }.sorted(by: { $0.path < $1.path })
//        var filteredCollection: [URL] = []
//        var previousUrl: URL?
//
//        for url in sortedCollection {
//            if let previous = previousUrl, url.path.hasPrefix(previous.path + "/") {
//                // Current URL is a subdirectory of the previous one, so skip it
//                continue
//            }
//            // This URL is not a subdirectory of the previous one, so keep it and set it as the previous URL
//            filteredCollection.append(url)
//            previousUrl = url
//        }
//
//        await handlePostProcessing(sortedCollection: filteredCollection)
//    }
//
//    private func handlePostProcessing(sortedCollection: [URL]) async {
//        for path in sortedCollection {
//            let size = totalSizeOnDisk(for: path)
//            if let icon = getIconForFileOrFolderNS(atPath: path) {  // Retrieve NSImage
//                let iconData = serializeImage(icon)  // Convert NSImage to Data
//                await state.setFileDetails(for: path, size: size, icon: iconData)  // Pass Data to actor
//            } else {
//                await state.setFileDetails(for: path, size: size, icon: nil)
//            }
//        }
//        await updateAppState(with: sortedCollection)
//    }
//
//    private func updateAppState(with sortedCollection: [URL]) async {
//        // Retrieve state from the actor
//        let fileSize = await self.state.getFileSize()
//        let fileIconData = await self.state.getFileIconData()
//        let fileIcons = fileIconData.mapValues { deserializeImage($0) }
//
//        // Assume updating of appInfo needs to happen on the main thread
//        self.appInfo.fileSize = fileSize
//        self.appInfo.fileIcon = fileIcons
//
//        // Execute UI related updates on the main thread using MainActor
//        await MainActor.run {
//            if !self.backgroundRun {
//                self.appState.appInfo = self.appInfo
//                self.appState.selectedItems = Set(sortedCollection)
//            }
//
//            
//        }
//
//        self.completion()  // Call the completion handler
//    }
//}
//
//actor PathFinderState {
//    var fileSize: [URL: Int64] = [:]
//    var fileIconData: [URL: Data?] = [:]
//
//    func setFileDetails(for path: URL, size: Int64, icon: Data?) {
//        fileSize[path] = size
//        fileIconData[path] = icon
//    }
//
//    func getFileSize() -> [URL: Int64] {
//        return fileSize
//    }
//
//    func getFileIconData() -> [URL: Data?] {
//        return fileIconData
//    }
//}
//
//
//func serializeImage(_ image: NSImage?) -> Data? {
//    guard let image = image else { return nil }
//    guard let tiffData = image.tiffRepresentation else { return nil }
//    let bitmapImage = NSBitmapImageRep(data: tiffData)
//    return bitmapImage?.representation(using: .png, properties: [:])
//}
//
//func deserializeImage(_ data: Data?) -> NSImage? {
//    guard let data = data else { return nil }
//    return NSImage(data: data)
//}

