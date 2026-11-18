# Sign-in screen

`SignInScreen` renders the framework-free sign-in model from `@inline/auth/flows` (`createSignInModel`, see `web/packages/auth/src/flows/README.md`). The model owns the steps, pending state, errors, the resend countdown and back; this folder only renders them and forwards input. Lab: `web/lab-signin.html` (source in `web/src/lab/signin/`).

## Mounting

```tsx
import { SignInScreen } from "~/features/signin"

// The app shell creates the model (wiring in the flows README) and owns its lifetime,
// e.g. `const model = useModel(() => createSignInModel({ api, authStore, clock: systemClock, signOut, provider }))`.
<SignInScreen model={model} />
```

| Prop | Default | What |
| --- | --- | --- |
| `model` | required | A `SignInModel`. |
| `enabledProviders` | `[]` | Providers whose buttons work. Google and Apple render disabled with a short reason until the server's provider route accepts a web client. |
| `navigate` | `location.assign` | Where a provider start URL goes. |
| `codeLength` | none | With it, the code is sent as soon as that many digits are typed or pasted, and longer input is cut. The model does not expose a length yet, so the shell decides (the server's codes are 6 digits today). |

The screen fills its container (`min-block-size: 100%`): give it the whole window. It uses the UI kit's color tokens (`light-dark()`), so the document needs `color-scheme` set (`light dark` for system). When the model reaches `done` (or the auth store reports a session), the shell replaces the screen with the app.

## Steps covered

One frame for every step: back control row (always reserved), the Inline mark, title, body, fields, one message region, actions, footer.

| Model step | Renders |
| --- | --- |
| `welcome` | Continue with email (primary), with phone; Google and Apple (disabled with reason unless enabled); terms and privacy links. |
| `email` | Email field (`type=email`, `autocomplete=email`), Continue. Prefilled with the model's contact on the way back. |
| `phone` | Phone field (`type=tel`, `inputmode=tel`, `autocomplete=tel`, left to right), hint about the country code, Continue. No phone library. |
| `invite` | Access invite code field, normalized to 8 upper-case letters and digits as typed; prefilled with the accepted code on the way back. Only when the model goes there. |
| `code` | "Check your email/messages", the destination as sent, one code field (`inputmode=numeric`, `autocomplete=one-time-code`, digits from any script mapped to ASCII, paste of "123 456" works), submit labelled Sign in, Create account or Continue (`existingUser`), and "Send a new code in m:ss" that turns into "Send a new code". A successful resend shows a success notice. |
| `provider` | Progress while starting or redeeming; after a provider error, "Sign-in didn't finish" with the reason and, if the provider is enabled, "Try again". Never redirects by itself. |
| `setup` | "Your account is ready", who is signed in, Continue (`finishSetup`). The back row says "Sign out" here, because the model's back signs out after authentication. |
| `done` | Success mark, "You're signed in", the user's name. No back. |

## Behavior

- Errors come only from `model.error` and appear in the step's message region, which is always rendered (`role=status`, polite) and reserves one line. A field is `aria-invalid` and described by the region only when the error is about its content (`isFieldError`); network, server and rate-limit errors leave the field valid. The view never changes the step on an error.
- Errors and notices are told apart by color and shape: red text with a filled exclamation mark, or label text with a green check.
- While a request runs: fields are read-only (they keep focus), the submit button is disabled and shows a spinner over its hidden label, so nothing moves; `aria-busy` is set on the form.
- Enter submits: every step with a field is a `<form noValidate>` with a submit button.
- Focus: each step mounts fresh, and a module-level ref callback (`focusOnMount`) focuses the step's field, or its title (`tabIndex=-1`) for steps without one, or Setup's Continue. After an error, the submit handler puts focus back in the field and selects its text. No effects.
- A wrong or expired code is cleared from the field; the code is never shown anywhere else.
- Typing after an error clears it (`model.clearError()`), as the Mac app does.
- Nothing is logged. Error text comes from the error kind only, never from server text.
- Right to left: logical properties only; emails, phone numbers and codes are isolated left to right (`<bdi dir=ltr>`, `dir=ltr` fields); names pick their own direction. The back chevron mirrors.
- Reduced motion: this folder's transitions use the kit's motion tokens (0 ms under `prefers-reduced-motion`). The kit's `Progress` spinner keeps its fixed 0.8 s rotation under reduced motion; that is the kit's to change.
- Fields are uncontrolled (`defaultValue`, read from the form on submit), so the view holds no copy of the typed text. The only component state is the code step's "a new code was sent" flag.

## Files

| File | What |
| --- | --- |
| `SignInScreen.tsx` | The screen, the shared frame, the message region, the submit button and every step. |
| `Field.tsx` | The text field: like the kit's `TextField`, but described by the shared message region instead of its own error text. |
| `icons.tsx` | The Inline mark, back chevron, error and success glyphs. |
| `format.ts` | Countdown (`m:ss`), rate-limit wait in words, code and invite input normalization, contact prefill, code completeness. Tested in `format.test.ts`. |
| `messages.ts` | Error sentences, which errors belong to the field or clear the code, pending labels, submit and resend labels, display name. Tested in `messages.test.ts`. |
| `focus.ts` | `focusOnMount` (ref callback) and `focusFieldAfterError`. |

Tests: `bunx vitest run src/features/signin` from `web/`.

## Lab

`lab-signin.html?theme=dark&dir=rtl&width=320` renders the screen over a real model, the real API client and a real in-memory `AuthStore`, with a scripted `fetch` (`lab-server.ts`). The strip picks the server's next answer (success, wrong code, expired code, rate limited, invite required, network failure, slow), a new account (sign-in comes back with `pendingSetup`), sending at 6 digits, enabling providers and simulating a provider return (with a ticket, cancelled, from another tab), plus appearance, direction and a 320 px stage. The panel prints the model's state; `globalThis.__signinLab` returns the same as plain data and `globalThis.__signinLabControl` drives the lab (`setNext`, `setNewAccount`, `setProvidersEnabled`, `setAutoSubmitLength`, `setTheme`, `setDir`, `setWidth`, `returnFromProvider`, `reset`).

How the answers map: on a send route, "wrong code" and "expired code" answer `EMAIL_INVALID` / `PHONE_INVALID`; "invite required" answers `needsInviteCode`. On verify, "expired code" moves the lab clock past the 10-minute email code lifetime and answers `EMAIL_CODE_INVALID`, which the model reports as expired (email only; phone codes are not inferred, as in the model). On the invite check, "wrong code" answers `valid: false`. "Rate limited" is 420 `FLOOD` with `retry-after: 30`. The answer applies to one request and then returns to success.

## Not verified without a browser

Nothing here has been rendered. Typecheck, lint and the helper tests pass, and every view file compiles with the StyleX Babel plugin (146 rules). Still to check in the lab: layout and wrapping at 320 px, light and dark, right to left, focus landing on each step and after errors, the spinner not shifting the button, `:focus-visible` rings, screen reader announcements of the message region, one-time-code autofill (Safari, iOS), pasting codes, `enterkeyhint` on mobile keyboards, and that `1lh` reserves the message line in every supported browser.
