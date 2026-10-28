import CloudKit
import Foundation

/// A failure that gives up waiting for CloudKit.
struct HouseholdTimeoutError: LocalizedError {
    let seconds: Int
    var errorDescription: String? { "CloudKit didn't respond within \(seconds) seconds." }
}

/// The iCloud account can't use CloudKit.
struct ICloudUnavailableError: LocalizedError {
    let status: String
    var errorDescription: String? { "iCloud isn't available (\(status)). Sign in to iCloud in Settings and try again." }
}

extension Error {
    /// A plain-language explanation for failures with a known cause, else `nil`.
    var friendlyExplanation: String? {
        let text = cloudKitDescription
        if text.contains("cloudkit.share"), text.contains("production schema") {
            return "Household invitations aren't set up in iCloud yet. This is a configuration problem, not something you did."
        }
        return nil
    }

    /// The error with its CloudKit code, for the alert and the debug log.
    var cloudKitDescription: String {
        guard let error = self as? CKError else { return localizedDescription }
        var text = "\(localizedDescription) [CKError \(error.code.rawValue) \(error.code.name)]"
        if let retryAfter = error.retryAfterSeconds { text += " retry after \(Int(retryAfter))s" }
        if error.code == .partialFailure, let failures = error.partialErrorsByItemID {
            text += " {" + failures.values.map(\.cloudKitDescription).joined(separator: "; ") + "}"
        }
        return text
    }
}

extension CKError.Code {
    var name: String {
        switch self {
        case .networkUnavailable: "networkUnavailable"
        case .networkFailure: "networkFailure"
        case .notAuthenticated: "notAuthenticated"
        case .permissionFailure: "permissionFailure"
        case .unknownItem: "unknownItem"
        case .zoneNotFound: "zoneNotFound"
        case .userDeletedZone: "userDeletedZone"
        case .partialFailure: "partialFailure"
        case .serverRejectedRequest: "serverRejectedRequest"
        case .serverRecordChanged: "serverRecordChanged"
        case .invalidArguments: "invalidArguments"
        case .badContainer: "badContainer"
        case .missingEntitlement: "missingEntitlement"
        case .quotaExceeded: "quotaExceeded"
        case .requestRateLimited: "requestRateLimited"
        case .zoneBusy: "zoneBusy"
        case .serviceUnavailable: "serviceUnavailable"
        case .internalError: "internalError"
        case .operationCancelled: "operationCancelled"
        case .constraintViolation: "constraintViolation"
        case .badDatabase: "badDatabase"
        case .managedAccountRestricted: "managedAccountRestricted"
        default: "code\(rawValue)"
        }
    }
}

extension CKAccountStatus {
    var name: String {
        switch self {
        case .available: "available"
        case .noAccount: "no account"
        case .restricted: "restricted"
        case .couldNotDetermine: "could not determine"
        case .temporarilyUnavailable: "temporarily unavailable"
        @unknown default: "unknown"
        }
    }
}
