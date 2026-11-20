# reproo – iOS SDK

Version 0.8.1 (`Reproo.sdkVersion`). Swift Package that lets testers report problems from an iOS app (iOS 15+). It presents the hosted reporting widget in a `WKWebView` sheet and delivers native context – and a screenshot of the screen the tester was on – through the same bridge the Web SDK uses (protocol v1, see `docs/sdk-and-protocol.md`). Crashes are recorded and sent on the next launch, where the tester is asked what they were doing. Without a connection the tester writes the report in a native form; it is kept on the phone and sent by itself once the app is online again (see *Offline reports*).

Two targets: `Reproo` (Swift) and `ReprooCrash` (C – the async-signal-safe crash handlers; SwiftPM cannot mix C and Swift in one target). Apps depend on the `Reproo` product only. A copy of the package needs `Package.swift` and both `Sources/Reproo` and `Sources/ReprooCrash`; `Package.swift` declares the test target only when `Tests/` is there, so a copy without it loads as it is.

## Install

In Xcode: *File → Add Package Dependencies…*, paste `https://github.com/lassesilk/reproo-ios`, choose *Up to Next Minor Version* from 0.8.1, and add the `Reproo` library only to the targets that should report – your dev or test target, if you have one (see *Only in a dev or test target*). Then `import Reproo`. In a `Package.swift`: `.package(url: "https://github.com/lassesilk/reproo-ios", .upToNextMinor(from: "0.8.1"))`.

The SDK does nothing without a project key, which a reproo customer gets on the project's SDK tab.

**Releasing (reproo's team):** the package is developed in the platform repository (`sdks/ios`) and published to the public repository with `pnpm sdk:ios:publish` – it copies `Package.swift`, `Sources`, this README and `LICENSE` (no tests) and tags `Reproo.sdkVersion`. Bump `Reproo.sdkVersion` and `IOS_SDK_VERSION` (`src/domain/sdk-snippets.ts`) first; a released tag is never moved.

## Only in a dev or test target

Most teams want reproo in the build testers get, not in the App Store build. With a separate target (e.g. *MyAppDEV*):

1. Link the `Reproo` library to the dev target only (*General → Frameworks, Libraries, and Embedded Content*).
2. Add `DEV` to that target's *Build Settings → Active Compilation Conditions* (Debug and Release).
3. Guard every use with `#if DEV && canImport(Reproo)`:

```swift
#if DEV && canImport(Reproo)
import Reproo
#endif

enum ReprooSetup {
    static func start() {
        #if DEV && canImport(Reproo)
        // The key in the dev target's Info.plist (ReprooProjectKey) – public, safe to commit. Empty: reproo stays off.
        let key = Bundle.main.object(forInfoDictionaryKey: "ReprooProjectKey") as? String ?? ""
        Reproo.configure(projectKey: key, host: URL(string: "https://app.reproo.no")!, environment: "staging", shakeToReport: true)
        #endif
    }
}
```

`canImport(Reproo)` alone is not enough: both targets build into the same products folder, so once the dev target has been built the other one sees the `Reproo` module too – and fails to build (*Unable to resolve module dependency: ReprooCrash*), as it does not link it. Keep the two targets' bundle ids apart, or archiving the dev scheme ships the SDK under the App Store app's id.

## Version, build and commit – set up once

Nothing to change per release. Version and build come from the bundle (Xcode's *Version* and *Build*), the release defaults to the version, and the git commit the app was built from – which lets the agent read the exact source the tester runs – comes from the build after this one-time step in each target that links Reproo. Push the commit to the repository connected in reproo: a build from a commit that is not there yet is analysed against the newest indexed code, and the report says so.

1. *Build Phases → + → New Run Script Phase*, named «Embed git commit (reproo)» and left at the end of the list (after *Copy Bundle Resources*), with this script (shell `/bin/sh`):

   ```sh
   # reproo: the git commit of this build, as ReprooCommit in the built Info.plist - Reproo.configure() reads it.
   # Set up once; nothing to change per release. Without git or a repository the build still succeeds, without a commit.
   plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
   stamp="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ReprooCommit.txt"
   [ -e "$SRCROOT/.git" ] && export GIT_CEILING_DIRECTORIES="${SRCROOT%/*}" # this repository, never one around it
   commit=$(git -C "$SRCROOT" rev-parse HEAD 2>/dev/null) || commit="${CI_COMMIT:-$GITHUB_SHA}" # Xcode Cloud, GitHub Actions
   if [ -z "$commit" ] && [ -e "$SRCROOT/.git" ] && [ "$ENABLE_USER_SCRIPT_SANDBOXING" = YES ]; then
     echo "warning: reproo: no commit, the script sandbox hides the .git next to the project. Set ENABLE_USER_SCRIPT_SANDBOXING = NO for this target."
   fi
   if [ "$(/usr/libexec/PlistBuddy -c "Print :ReprooCommit" "$plist" 2>/dev/null)" != "$commit" ]; then
     if [ -n "$commit" ]; then /usr/bin/plutil -replace ReprooCommit -string "$commit" "$plist"; else /usr/bin/plutil -remove ReprooCommit "$plist"; fi ||
       echo "warning: reproo: could not update ReprooCommit. Check the phase's input and output files."
     rm -f "$stamp" # written again below: a changed file in the app makes Xcode sign it again
   fi
   [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$commit" ] || echo "$commit" > "$stamp"
   exit 0
   ```

2. Uncheck *Based on dependency analysis* – the commit changes without any file of the project changing. Xcode then notes on every build that the phase runs on every build: that is intended.
3. *Input Files*: `$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)`. *Output Files*: `$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)` and `$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ReprooCommit.txt`.
4. Only if the `.xcodeproj` lies at the root of the repository, next to `.git`: set *User Script Sandboxing* (`ENABLE_USER_SCRIPT_SANDBOXING`) to *No* for the app target. A project in a subfolder of the repository (like `demo-ios/`, or the `ios/` folder of a React Native or Flutter app) keeps the sandbox on.

- Every build – debug, release, archive, CI – runs `git rev-parse HEAD` in the project folder and writes the result into the *built* app's Info.plist as `ReprooCommit` (the project's own Info.plist is not touched). `Reproo.configure()` reads it when no `commitSha` is passed (a `commitSha` passed to `configure` wins); only 7–64 hex characters count, so an empty value or an unexpanded `$(…)` is ignored. Apps that pass `release` and `commitSha` by hand can drop them.
- Works with Xcode's script sandbox (`ENABLE_USER_SCRIPT_SANDBOXING = YES`, the default for new projects): the declared input and output files are what lets the script edit the built Info.plist. The sandbox also hides the project's own folder from scripts: a `.git` above it can be read, a `.git` next to the `.xcodeproj` cannot – and no input file can open it, as git needs the current branch's file – hence step 4. Without step 4 such a project builds with a warning and no commit.
- The second output, `ReprooCommit.txt` in the app (the commit again, 41 bytes), makes Xcode sign the app again when only the commit changed – it does not notice the edited Info.plist by itself, and the signature would no longer match. A build in which nothing changed only runs the script.
- Never breaks the build: without `git`, outside a repository (a source archive) or in a repository without commits no commit is written, and the SDK sends none. Uncommitted changes in a local build are not part of it.
- On CI the checkout has the commit; where git cannot be read, the script takes Xcode Cloud's `CI_COMMIT` or GitHub Actions' `GITHUB_SHA`.
- Check a build: `/usr/libexec/PlistBuddy -c "Print :ReprooCommit" path/to/App.app/Info.plist`.

## Use

```swift
import Reproo

// AppDelegate / App init
Reproo.configure(
    projectKey: "rp_pk_…",                                   // Projects → SDK setup – public, safe to ship in the app
    host: URL(string: "https://app.reproo.no")!,             // the platform (its APP_URL, e.g. your staging platform; locally http://localhost:3000)
    environment: "staging",                                  // exactly one of the project's environments
    shakeToReport: true                                      // optional: shaking the phone opens the report (default: off)
    // captureCrashes: false                                 // opt out of crash capture (default: on; the project's setting applies too)
)

// On every sign-in – a stable id (not an e-mail address) and the role – and on sign-out
Reproo.setUser(id: user.id, role: user.role)
Reproo.setUser(id: nil, role: nil)

// While the user navigates
Reproo.setContext(["screen": "CreateCustomer", "route": "/customers/new", "featureFlags": ["newCustomerFlow": true]])
Reproo.setContext(["customerId": NSNull()])                   // NSNull() removes a key
Reproo.addBreadcrumb(type: .action, message: "Pressed Save")

// Errors the app handles itself (sent as console output)
Reproo.log("Saving the customer failed: 422", level: .error)

// Your «Meld inn problem» button – SwiftUI …
Button("Meld inn problem") { Reproo.reportProblem() }
// … or UIKit (reportProblem is @MainActor)
Reproo.reportProblem(from: viewController)

// Optional: reports saved without a connection that wait to be sent
let waiting = Reproo.pendingReportCount
```

- **Off without a key.** `configure` with an empty project key, the guide's `"rp_pk_…"` placeholder or anything else the platform would refuse (or a host that is no `http(s)` address) logs one warning in the console (`no.reproo`, category `setup`) and configures nothing – no crash handlers, no network. `reportProblem()` before a valid `configure` logs the same way and returns. Neither crashes a debug build.
- **The user.** Call `setUser` again whenever sign-in state changes, and `setUser(id: nil, role: nil)` on sign-out. Follow-up questions, *Learn versions* (a version at least two testers report from becomes the environment's test version) and duplicate detection rely on the id; the role helps the agent with permission problems. Send `name:` and `email:` only if the project collects them (Privacy & AI) – they are sent like the Web SDK's and fill in the offline form.
- **Shake to report** (`shakeToReport: true`, Simulator: *Device → Shake*): the SDK gives `UIWindow` its own `motionEnded(_:with:)`, which calls the implementation it had – an override your app added, or `UIResponder`'s – and then opens the report. `UIResponder`'s own method, shared by every view, is never touched; a window subclass that overrides `motionEnded` reaches it through `super`. A shake while a reproo sheet is up opens nothing.
- **Where the button sits.** A button on a settings screen attaches a screenshot of that screen, not of the problem: prefer a shake, or a button on every screen.

## Before the first test

- **Environment:** `environment` must be exactly the name of one of the project's environments (the SDK tab lists them) – otherwise reports are linked to no environment.
- **Version:** reproo compares the app's version and build with the environment's iOS test version and marks a report from an older build as outdated. A dev target with numbering of its own (*MyAppDEV 1.0 (17)* next to the App Store's *2.5*) needs that version in the environment (*General*), or every report counts as an outdated build.
- **The key is public** – safe to commit (Info.plist, an xcconfig) and to ship in the app; it can only start and continue reports, send crash reports and load the project's public report-form settings – never read reports, code or other data. Each app has its own key: revoke a leaked one on the SDK tab.
- **Screenshot:** it shows the screen the tester was on – a map with their position, a profile with their e-mail. The tester can remove it before sending; `attachScreenshot: false` turns it off.

Version, build, app name, release and commit need no code: they default to the bundle's version, build and name, the version and the build's `ReprooCommit` (see above). `version`, `build`, `appName`, `release` and `commitSha` can still be passed; a value passed wins.

## Network requests and log messages

- **Requests** of every `URLSession` – `URLSession.shared`, the app's own sessions and Alamofire's – are recorded
  automatically (`captureNetwork: true`, the default): method, URL, status, duration and content type of the last 30 –
  **never headers or bodies**. The SDK only watches the app's own tasks (it notes each one as it is resumed and
  records it when it completes); it never sends, forwards or changes a request, so streams, session and per-task
  delegates (authentication, certificate pinning, redirects), cookies, caches, upload bodies and the app's own
  `URLProtocol`s work exactly as without reproo. Credentials, fragments and sensitive query values (`token`, `key`,
  `password`, …) are removed from the URL – other query values and path segments are sent as they are, so turn
  capture off (`captureNetwork: false`) for an app whose URLs carry personal data (a location in the query, an
  invitation token in the path). Requests to the platform itself are skipped. Other networking stacks:
  `Reproo.recordNetworkRequest(method:url:status:duration:error:)`.
- **`Reproo.instrument(_:)`** (before 0.8.1) is no longer needed: it does nothing and can be removed. Until 0.8.1 the
  SDK sent captured requests again through a session of its own, which held back streamed responses and skipped
  the app's session delegates – update from 0.8.0 or older.
- **Log messages** – `Reproo.log(_:level:)` for problems the app handles itself (the last 30; identical consecutive
  messages are folded). E-mail addresses, bearer tokens, JWTs and `password=…`-style pairs are scrubbed.

Both arrive in the report as the protocol's `network` and `console` evidence – the same signals the Web SDK
captures («the save request returned 422», «no request after the tap on Save», «the same POST sent twice»).

## What is sent

`platform: "ios"`, SDK name/version, session id (per launch), environment, app name/version/build (from the bundle unless overridden), release (the version unless given), the git commit (the built Info.plist's `ReprooCommit` unless given), the app's bundle identifier (`app.id`, from `Bundle.main.bundleIdentifier` – the project's SDK tab lists the apps each key was used from, so a key that turns up in an unknown app shows), device type + model identifier (e.g. `iPhone17,1`), iOS version, locale (the device language – an English-only app on a Norwegian phone still gets the widget in Norwegian), time zone, screen name, screen size/scale, user id/role (and name/e-mail when the app passes them to `setUser`), custom context, the connection (`connectivity`: online/offline/unknown, Wi-Fi/cellular/ethernet/other, expensive, Low Data Mode, since when), the last 50 breadcrumbs (e-mail addresses and tokens scrubbed; losing and regaining the connection are breadcrumbs too), the last 30 requests (a failed one with its `errorCode`, e.g. `NSURLErrorDomain:-1009`, and `offline: true` when the device had no connection – so «no coverage» is never read as a server error) and log messages. Once the report has been created, what it contained is removed from the SDK's buffers (and from the crash black box), so the next report only carries what happened after it; the platform also keeps a report's evidence to the 10 minutes before the sheet was opened. With `attachScreenshot: true` (default) a JPEG of the key window (max 1600 px) is captured *before* the sheet opens and offered as an attachment the tester can remove before sending.

## Offline reports

Testers in the field are often without a connection for hours. The AI interview needs the platform; everything else does not: **capture now, ask later**.

- **Writing.** `reportProblem()` while the device is offline (as `NWPathMonitor` last said) opens a native form instead of the widget: «Hva skjedde? Hva prøvde du å gjøre?» (required), the screenshot (shown, removable) and – when the project asks for them – name and e-mail, prefilled from `setUser`. Which fields to show comes from the project configuration the SDK last fetched (`GET /api/v1/project`, kept per platform and project key). The same form replaces the report page when the page does not load: a load error, an HTTP status ≥ 400 for the page, or no finished load within 12 s – with the same screenshot and context. After «Lagre»: «Lagret – sendes automatisk når du har nett.» Texts in Norwegian or English after the device language; Dynamic Type, VoiceOver, light and dark mode, and the keyboard never covers the field being edited.
- **From the widget.** The bridge's `init` says `capabilities: ["outbox"]`. When the widget cannot create a report (no response), it can offer «Lagre og send når jeg har nett» and posts `save-offline` with the message, the reporter, its `clientReportId` and `screenshot` (whether the screenshot the SDK attached is still among the attachments); the SDK saves it with that id (the widget sends the same id on every attempt, so an attempt that did reach the platform is never stored twice) with the sheet's frozen context – and the screenshot, unless the tester removed it (`screenshot: false`; a widget that does not say keeps it). Saving the same id again never makes a second item: it replaces the saved one while the platform does not have it yet (keeping when it was first saved), and keeps the saved one once it does. Every `save-offline` is answered in the page with `{ source: "uatai", type: "save-offline-result", clientReportId, ok, reason? }` (`reason`: `"full"` – 20 reports already wait – or `"failed"`); the widget confirms it or explains the refusal itself, the SDK shows nothing. When the tester then sends it from the widget after all («Prøv igjen», the same id), the widget's `report-created` carries that `clientReportId` and the SDK deletes the saved item: the widget's report owns it (no second send, no follow-up of its own). A run of the outbox under way at that moment skips the item before each step – created again, the platform's replay would issue a new reporter token and the widget's would stop working.
- **Frozen.** A saved report keeps the context of the moment the tester opened the sheet – time, screen, the last actions, requests and log messages, the connection – and those buffers start fresh, as after a sent report.
- **Kept.** `Application Support/no.reproo/outbox/<clientReportId>/item.json` + `screenshot.jpg` – app-private, excluded from backup, file protection *until first unlock* (so a send in the background still reads them). At most 20 reports, each for 7 days from when it was saved: a full outbox refuses a new report with a message instead of dropping a saved one; an expired report is deleted (a debug log line, nothing else). A folder without its `item.json` (the app died while saving) is deleted once it is older than 10 minutes; an `item.json` that is there but cannot be read is never deleted. Between a restart and the first unlock (an app relaunched in the background) the outbox cannot be read – a hidden probe file with the same protection tells – and nothing is deleted, counted as sendable or sent; the unlock (`protectedDataDidBecomeAvailable`) sends it. `Reproo.pendingReportCount` tells how many wait.
- **Sent by itself** at launch (`configure`), when the app comes to the foreground, when the connection returns while it runs or moves to another kind of network while online (cellular → Wi-Fi), and right after a report was saved while the device is online – one at a time, oldest first, on the SDK's own session (never recorded as the app's traffic): `POST /api/v1/reports` with the frozen context, the message, `clientReportId`, `offline: { capturedAt }` and the platform's own origin as `hostOrigin`; the report id and reporter token are stored before the screenshot is uploaded, then the item is deleted. No response, a timeout, 402, 408, 425, 429 and 5xx keep it and end the run (429 – or any `Retry-After` – pauses the outbox for that long, and another run follows when the pause is over, as long as the app runs; a project that is not ready for reports yet answers `503` with `Retry-After`); any other 4xx deletes it. A run that got no answer at all while the device is online is followed by another – after 30 s, doubling up to 10 minutes, as long as the app runs; any answer starts that count again. Retries reuse `clientReportId`, so a lost response never makes a second report. A send that runs into the background finishes in a background task. Older platforms ignore `clientReportId` and `offline`.
- **Asked later.** A sent report whose tester can still be asked goes into `no.reproo/followups.json` (one list for offline reports and crashes, at most 20 entries for 7 days). When the app is active, online and no reproo sheet is shown, the entries are checked oldest first (`GET /api/v1/reports/{id}`) until one takes the tester's words (`report.acceptsMessages`); the app then asks «Problemet du lagret 12.11 kl. 14:32 – Rapporten er sendt. Vil du svare på et par korte spørsmål, så blir den bedre?» (with the tester's first words), one question at a time – or, when what waits is a possible answer (`report.stage` `EXPLAINED`), «Reproo har et mulig svar på problemet du lagret. Vil du se det?» with «Se svaret» / «Nei takk». The question is an alert in a window of its own above the app's (alert level), never presented on the app's controllers, so nothing the app presents or dismisses takes it away; the window is shown without becoming the key window, so «report a problem» (and its screenshot) still uses the app's screen. Should the question vanish unanswered anyway – or its window lose its scene (an iPad window closed from the app switcher, a scene disconnected in the background) – a later look asks again. A check that comes while a question is on screen (the app comes back, a report was sent, a look comes due) follows a second after it is over; after «Nei takk» the next report is looked at. «Svar nå» / «Se svaret» opens the report's conversation on the app's screen; the entry goes once that page has loaded (it stays when it cannot load – the sheet then says «Du er uten nett»). «Nei takk» is remembered and `finish_now` is sent until the platform has heard it (`2xx`, `404` or `410`); a `409` is not heard – the report is looked at, and the entry is dropped only when it no longer waits (otherwise it is tried again, after 30 s doubling up to 10 minutes while the app is in the foreground, and at the next look). An entry is dropped when its report is finished (status other than `NEW` / `INVESTIGATING`) or the platform answers `401`, `403`, `404` or `410`. While a report is still `NEW` or `INVESTIGATING` without taking words (the agent has not asked yet, or is writing), its entry stays and is looked at again – after 30 s, doubling up to 10 minutes – as long as the app is in the foreground. No answer, a rate limit or a server error ends the check until the next one.

To try it in the Simulator (it shares the Mac's network): stop the platform, or turn off the Mac's network, then «report a problem»; start it again and bring the app to the foreground.

## Crash capture

On by default (`configure(captureCrashes: false)` turns it off: nothing is installed and anything stored earlier is deleted – also when an earlier `configure` of the same run had turned it on: the handlers are uninstalled and the black box stops).

**The project's setting** (*Capture crashes automatically* in the project settings) applies as well. The platform's answer to the SDK's start signal (`GET /api/v1/project`, sent by `configure` on the SDK's own session, never recorded) carries it as `crashReporting.enabled`, and the SDK remembers the last answer per platform and project key (`UserDefaults`). When the project has it turned off, everything stored is deleted – black box, journal, image list, crashed runs, unsent reports and crash follow-ups (offline reports and their follow-ups stay) – and recording stops for the rest of the run: the handlers are uninstalled (the previous ones restored) and the black box is no longer written. Later launches install nothing until an answer says it is on again; recording then starts in that same run. Until the first answer (first launch, offline) `captureCrashes` alone decides; the platform refuses crash reports for a project that has it turned off either way.

**While the app runs** the SDK keeps a small *black box* on disk – the same `ClientContext` a manual report sends (release, commit, screen, route, user, custom context, breadcrumbs, requests, log messages) of the *current* run, rewritten about 0.5 s after a change on a background queue – plus the list of loaded binary images (name, UUID, load address, `__TEXT` size), written when crash capture starts. Breadcrumbs, screen/route changes and requests are also appended to a small journal the moment they happen, so the tap that crashes the app a millisecond later (or the response it crashed on) is in the report even though the black box was not rewritten yet. At launch the previous run's files are removed before the handlers are installed, so an early crash is never paired with another run's release or image list. No screenshot, no request headers or bodies.

**When the app crashes** – a fatal signal (`SIGABRT`, `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE`, `SIGTRAP`, `SIGSYS`; Swift runtime traps such as a force unwrap of `nil` arrive as `SIGTRAP`) or an uncaught Objective-C exception – the C handlers write a short record: signal or exception name and reason, the Swift runtime message (e.g. `CheckoutForm.swift:24: Fatal error: Unexpectedly found nil while unwrapping an Optional value`, read from libswiftCore's crash annotations), the time, whether the app was in the foreground and the crashed thread's return addresses. The handlers are async-signal-safe (no locks, no allocation, no Swift/Foundation) and chained: previously installed handlers (Crashlytics, Sentry …) and the system crash report still run. When two threads crash at once, the second waits (at most about 2 s) until the first has written the record. Stack overflows are captured on the main thread (it gets its own alternate signal stack, also when `configure` runs on another thread) – not on other threads.

**On the next launch** (inside `configure`, before this run writes anything) the record and the crashed run's black box become a crash report:

- frames top first, each with image and offset; frames of the app's own code are symbolicated on the device when the same build runs again (`dladdr` + `swift_demangle` → `MyApp.CheckoutForm.init(cart: …)`). The SDK's own frames are never marked as app code. No file/line on the device – the runtime message carries it for Swift traps, and image + offset + UUID let the platform symbolicate with a dSYM later.
- it is sent in the background to `POST /api/v1/crashes` (header `x-reproo-project-key`) with a `clientReportId` – the random id the crashed run got when it was moved aside, so a retry (or the same run processed twice) is recognised as the same crash – using a dedicated ephemeral `URLSession` that network capture never sees. The report goes to the platform and project key **of the crashed run**. Accepted → the tester is asked if the report still takes their words (`report.acceptsMessages`); rejected (400/401/403 – e.g. `crash_reporting_disabled` – 404, 410) → deleted; offline, 402, 429 or 5xx → retried on later launches for up to 7 days. At most 5 reports wait.
- a report that was not sent (offline) is tried again – like the outbox – when the app comes to the foreground and when the connection returns.
- between a restart and the first unlock (an app relaunched in the background) the crashed run and unsent reports are there but cannot be read: nothing is deleted or sent, and they become reports and go at the unlock (`protectedDataDidBecomeAvailable`) or the next trigger.
- the report becomes a follow-up (see *Offline reports* → *Asked later*): once the app is active, online and nothing else is being presented, and only while the platform still takes the tester's words, an alert asks «Appen ble avsluttet uventet – Vil du fortelle hva du gjorde rett før? Det hjelper utviklerne å rette feilen.» (English on non-Norwegian devices; with the time when the crash lies more than an hour back: «Appen ble avsluttet uventet 12.11 kl. 14:32»). «Fortell hva som skjedde» opens the widget on that report's conversation (no screenshot); «Nei takk» lets the agent finish the report from the crash alone (`finish_now`, sent until the platform has heard it). The platform finishes unanswered crash reports after 20 minutes; a later check finds that and asks nothing. An unasked crash prompt of an SDK before 0.7 (`ai.uatai/prompt.json`) is moved into the follow-ups by the next `configure` – or, when it cannot be read yet (before the first unlock), at the unlock; the file goes only once its entry has been written.

**Privacy.** Files live in `Application Support/ai.uatai` (the SDK's former name, kept – see *Upgrading from UATAI*) inside the app sandbox, excluded from backup, with file protection *until first unlock*. Breadcrumbs, log messages and an uncaught exception's reason are scrubbed (e-mail addresses, tokens, `password=…`) before they are written; the Swift runtime message is copied inside the signal handler, where scrubbing is not safe, and is scrubbed on the next launch before it is sent. The platform redacts again. The reporter token of a sent crash is kept in the protected follow-up file only until the tester has answered, declined or the platform no longer takes their words (at most 7 days). Everything is deleted once sent. Testers never see technical details: the prompt and the widget only say the app closed unexpectedly – frames, symbols, file names and signal names are for the developers' dashboard.

**Verify.** The debugger catches signals and exceptions first, so under Xcode *Run* the handlers never fire. Build, install and launch without it:

```bash
xcrun simctl install booted path/to/App.app
xcrun simctl launch booted com.example.app   # trigger the crash, then launch again the same way
```

The second launch sends the crash and shows the prompt; the report appears in the dashboard with the crash, the last actions and the crashing code at the build's commit. Files to inspect: `xcrun simctl get_app_container booted com.example.app data` → `Library/Application Support/ai.uatai`.

## How it works

1. `reportProblem()` captures the screenshot, builds the `ClientContext` and presents `ReportViewController` as a page sheet with a visible grabber – testers close it with ✕ or by swiping down (the web view's page-level bounce is off, so the swipe reaches the sheet). Offline, the sheet starts with the native form instead.
2. The view controller loads `APP_URL/embed/report?k=<key>` and injects a bridge script at document start. Its `WKNavigationDelegate` watches the first load (load errors, HTTP ≥ 400, 12 s) and swaps in the native form when the page does not come.
3. When the widget posts `ready`, the script posts `init` (context, `capabilities: ["outbox"]`) and `attach` (screenshot) to the page – exactly what the Web SDK sends from the host page – and forwards `close` / `report-created` (with the `clientReportId` the report was created with) / `report-completed` / `save-offline` to native code via `WKScriptMessageHandler` (`save-offline` only when the page itself posted it). The answer to `save-offline` (`save-offline-result`) is posted into the page with `evaluateJavaScript` (`window.postMessage(…, '*')`).

A fully native UI can later replace the web view by rendering `ReportResponse.messages` and calling the REST endpoints directly; the protocol is the same.

## Tests

```bash
cd sdks/ios
xcodebuild test -scheme Reproo -destination 'platform=iOS Simulator,id=<simulator UDID>'   # xcrun simctl list devices
# Bridge integration test against a running local platform (pnpm dev):
TEST_RUNNER_UATAI_E2E_HOST=http://localhost:3000 TEST_RUNNER_UATAI_E2E_PROJECT_KEY=rp_pk_… xcodebuild test -scheme Reproo -destination 'platform=iOS Simulator,id=<simulator UDID>'
```

`swift test` on macOS builds but runs no tests (everything is iOS-only). The crash tests never raise a signal: they exercise the record writer directly, use fixture files for the crashed run and a `URLProtocol` stub for the platform. The offline tests use the same stub, a temporary outbox, a hand-moved clock, a hand-run timer for the runs the outbox plans by itself (when a `Retry-After` pause ends, after one without an answer), a switch for whether protected files can be read and a fake path monitor – no real network or connectivity changes. `OfflineDeliveryE2ETests` runs against a local platform (see its header): saved offline → sent when the connection returns → the follow-up question; «Svar nå»; «Nei takk» → the report is finished.

Note: the SDK opens the widget as a page of the platform's own origin (`APP_URL`), which the platform always allows. A project's *Allowed web origins* only applies to websites that embed the widget – native apps need no entry.

## Upgrading from UATAI (0.5.x)

Version 0.6.0 renamed the SDK: package, product and module `Reproo` (was `UATAI`; the C target `ReprooCrash` was `UATAICrash`), so `import Reproo` and `Reproo.configure(…)`, `Reproo.reportProblem()` … instead of `UATAI.…`. The SDK now sends `x-reproo-project-key`, `x-reproo-reporter-token` and `x-reproo-sdk`, and reports itself as `reproo-ios`. Project keys and reporter tokens of the former format (`uat_pk_…`, `uat_rt_…`) stay valid – no new key is needed.

Unchanged on the device, so an app updated from an older build keeps its pending crash reports, an unasked crash prompt and open conversations: the folder `Application Support/ai.uatai`, the `UserDefaults` keys `ai.uatai.crashReporting|…`, the widget's storage key `uatai.report.<key>` and the bridge's message source `"uatai"`. A crash recorded by the older build is sent by the updated one; its SDK frames (module `UATAI`, C functions `uatai_…`) still count as the SDK's own code, never as the app's.
