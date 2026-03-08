# iOS Experimental Logout/Login Empty State Fix

## Bug

- In the iOS experimental root, logging out and then logging back in can leave chats and spaces empty.
- The app routes back to `.main`, but the experimental home bootstrap does not rerun, so the cleared DB never gets repopulated.

## Root Cause

- `ExperimentalRootView` owns auth-session state (`ExperimentalNavigationModel`, `DataManager`, `HomeViewModel`, `CompactSpaceList`, tab/search state) above the `.main` / `.onboarding` switch.
- Logout only changes `MainViewRouter.route`; it does not recreate those objects.
- `ExperimentalNavigationModel.didRunHomeBootstrap` stays `true` across logout, so the next login skips `getMe/getChats/getSpaces`.

## Fix

- Move experimental main-session state into a dedicated authed subtree that is only created for `.main`.
- Keep onboarding/router/auth shell state at the top level.
- Preserve the existing `localDataCleared` refetch hook inside the authed subtree.

## Validation

- Re-login should reconstruct the experimental authed root and rerun the initial bootstrap fetch.
- Focused validation: inspect buildability of touched Swift code as far as allowed without full app `xcodebuild`.
