# Network Security Configuration

Since we removed the Info.plist file, you need to configure network settings in Xcode:

## Option 1: Using Xcode UI (Recommended)

1. Open VideoDemo.xcodeproj in Xcode
2. Select the **VideoDemo project** (blue icon) in the navigator
3. Select the **VideoDemo target** under TARGETS
4. Click the **Info** tab
5. In the "Custom iOS Target Properties" section:
   - Hover over any row and click the **+** button
   - Type: `App Transport Security Settings` (or select it from dropdown)
   - Click the disclosure triangle to expand it
   - Click the **+** button next to it
   - Add: `Allow Arbitrary Loads`
   - Set value to: **YES**

## Option 2: Using Build Settings (Alternative)

1. Open VideoDemo.xcodeproj in Xcode
2. Select the **VideoDemo project**
3. Select the **VideoDemo target**
4. Click the **Build Settings** tab
5. Search for "Info.plist"
6. Under "Packaging" → "Info.plist Values"
7. Add a custom entry:
   - Key: `NSAppTransportSecurity`
   - Value: `{ NSAllowsArbitraryLoads = YES; }`

## Why This Error Happened

Modern Xcode projects (Xcode 14+) automatically generate Info.plist at build time. Having a manual Info.plist file causes a conflict where two Info.plist files are trying to be copied to the same location.

## Verification

After configuration, clean and rebuild:
1. Product → Clean Build Folder (Shift+Cmd+K)
2. Product → Build (Cmd+B)

The error should be gone!

## For Production Apps

Replace the "Allow Arbitrary Loads" with specific exceptions:

```
App Transport Security Settings
└── Exception Domains
    └── yourdomain.com
        ├── NSIncludesSubdomains: YES
        └── NSTemporaryExceptionAllowsInsecureHTTPLoads: YES
```

This is more secure than allowing all arbitrary loads.





