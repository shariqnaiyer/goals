# Setup & Build

This repo contains a native iOS app (`App/`), its pure-Swift domain package
(`Packages/GoalsCore/`), and a thin LLM proxy (`proxy/`). See
[docs/PLAN.md](docs/PLAN.md) for the full architecture.

## Prerequisites

- Xcode 15+ (iOS 17 SDK), macOS 14+
- [XcodeGen](https://github.com/yonwoo9/XcodeGen) (`brew install xcodegen`) to
  generate the app's `.xcodeproj` from the committed `project.yml`
- (Optional) Node 18+ and `wrangler` to run the LLM proxy

## 1. Run the core package tests (no Xcode needed)

`GoalsCore` is platform-independent and holds the scheduler, planning and
adaptation logic with full unit coverage:

```sh
cd Packages/GoalsCore
swift test
```

## 2. Build & run the app

```sh
cd App
xcodegen generate          # writes Goals.xcodeproj from project.yml
open Goals.xcodeproj        # then ⌘R on an iOS 17 simulator
```

The app runs **out of the box with no backend** — it uses a deterministic
offline `MockLLMService`, so onboarding, planning, scheduling, the coach chat
and adaptation all work without any API key.

## 3. (Optional) Enable the live AI coach

Deploy the proxy and point the app at it:

```sh
cd proxy
npm install
npx wrangler secret put ANTHROPIC_API_KEY   # paste your key
npm run deploy                              # prints the Worker URL
```

Then:

```sh
cd App/Goals/Resources
cp Secrets.example.xcconfig Secrets.xcconfig
# edit Secrets.xcconfig → set LLM_PROXY_BASE_URL to your deployed Worker URL
cd ../../.. && cd App && xcodegen generate
```

`Secrets.xcconfig` is git-ignored. With it set, `AppContainer` selects the
networking `LLMClient` instead of the mock (see `App/Goals/App/Config.swift`).

## 4. (Optional) Enable the Google Calendar integration

The app schedules around your calendar and can export sessions to a dedicated
"Goals" calendar. Without these steps the integration simply shows as
"setup required" — everything else works.

1. In [Google Cloud Console](https://console.cloud.google.com), create (or
   pick) a project and enable the **Google Calendar API**.
2. Configure the OAuth consent screen (External; **Testing** mode is fine for
   development — add your Google account as a test user). Add the scopes
   `…/auth/calendar.readonly` and `…/auth/calendar.app.created`.
3. Credentials → *Create OAuth client ID* → **iOS**, bundle ID
   `com.shariqnaiyer.goals`. Copy the client ID.
4. In `App/Goals/Resources/Secrets.xcconfig`, set:

   ```
   GOOGLE_OAUTH_CLIENT_ID = <your-client-id>.apps.googleusercontent.com
   GOOGLE_OAUTH_REVERSED_CLIENT_ID = com.googleusercontent.apps.<your-client-id>
   ```

5. `cd App && xcodegen generate` (resolves the GoogleSignIn package and injects
   the plist keys), then build.

## Project layout

```
Packages/GoalsCore/   Pure domain layer (models, Scheduler, planning, LLM contracts) + tests
App/Goals/            SwiftUI app — App/, Persistence/, Services/, ViewModels/, Views/
App/project.yml       XcodeGen spec (source of truth for the .xcodeproj)
proxy/                Cloudflare Worker LLM proxy (TypeScript)
docs/PLAN.md          Product & technical plan
```
