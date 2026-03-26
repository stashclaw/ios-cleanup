import BackgroundTasks
import Photos
import Foundation

/// Owns registration and scheduling of the overnight pre-score BGProcessingTask.
/// Call `registerAll()` once at app launch (before first runloop tick, i.e., in App.init).
enum BackgroundScanScheduler {

    static let taskID = "com.yourname.iOSCleanup.prescore"

    // MARK: - Registration

    static func registerAll() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskID,
            using: nil   // nil = handle on main queue
        ) { task in
            handle(task: task as! BGProcessingTask)
        }
    }

    // MARK: - Scheduling

    /// Schedule the next run. Safe to call multiple times — OS deduplicates.
    static func scheduleIfNeeded() {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresNetworkConnectivity = false
        // MLUpdateTask fine-tuning runs overnight on charger to avoid draining battery.
        request.requiresExternalPower = true

        // Earliest fire: next 2 AM
        var components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        components.hour = 2
        components.minute = 0
        let earliest = Calendar.current.nextDate(
            after: Date(),
            matching: components,
            matchingPolicy: .nextTime
        ) ?? Date(timeIntervalSinceNow: 3600 * 6)

        request.earliestBeginDate = earliest

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch BGTaskScheduler.Error.notPermitted {
            // Entitlement not configured — silent fail in dev
        } catch {
            // Other scheduling errors — non-fatal
        }
    }

    // MARK: - Handler

    private static func handle(task: BGProcessingTask) {
        scheduleIfNeeded()  // always re-schedule before doing work

        let scanTask = Task {
            await runPrescore()
        }

        task.expirationHandler = {
            scanTask.cancel()
        }

        Task {
            await scanTask.value
            task.setTaskCompleted(success: !Task.isCancelled)
        }
    }

    // MARK: - Work

    private static func runPrescore() async {
        // Never prompt permissions in background
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        // Run the three main photo scan engines and write results to the shared cache.
        // HomeViewModel reads from this cache on next foreground launch.
        let cacheManager = BackgroundScanCacheWriter()
        await cacheManager.run()
    }
}
