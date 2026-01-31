//
//  ByteFormatter.swift
//  VideoDemo
//
//  Utility for formatting byte values into human-readable strings
//

import Foundation

/// Formats byte count into human-readable string
/// - Parameter bytes: The number of bytes
/// - Returns: Formatted string like "1.2 MB", "500 KB", or "128 bytes"
func formatBytes(_ bytes: Int64) -> String {
    let kb: Double = 1024
    let mb: Double = kb * 1024
    let gb: Double = mb * 1024

    let bytesDouble = Double(bytes)

    if bytesDouble >= gb {
        return String(format: "%.2f GB", bytesDouble / gb)
    } else if bytesDouble >= mb {
        return String(format: "%.2f MB", bytesDouble / mb)
    } else if bytesDouble >= kb {
        return String(format: "%.2f KB", bytesDouble / kb)
    } else {
        return "\(bytes) bytes"
    }
}

/// Formats byte count into human-readable string (Int overload)
/// - Parameter bytes: The number of bytes
/// - Returns: Formatted string like "1.2 MB", "500 KB", or "128 bytes"
func formatBytes(_ bytes: Int) -> String {
    return formatBytes(Int64(bytes))
}
