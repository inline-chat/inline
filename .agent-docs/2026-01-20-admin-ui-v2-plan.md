# Admin UI v2 plan (2026-01-20)

## Goals
- Switch to shadcn sidebar layout with a minimal top bar and brand asset usage.
- Add overview page and waitlist page, plus expanded app/user metrics and session detail.
- Harden login UX: default email+password+OTP, no email-code login when already signed in.
- Keep typography smaller and system font; align visual tone to web/landing brand assets.

## Plan
1) UI foundation
   - Add shadcn sidebar components + update theme tokens.
   - Update AppLayout to use sidebar layout and a minimal header.
   - Copy brand asset(s) into admin/public and use in sidebar header.

2) Routing + pages
   - Add Overview page as the index route.
   - Add Waitlist page with count + list.
   - Update nav items to include Overview/Waitlist and adjust existing routes.

3) Backend/admin data
   - Add waitlist count/list endpoints.
   - Expand user list to include avatar URL.
   - Expand user detail sessions to include decrypted personal data + client/os info.
   - Add overview metrics endpoint (or reuse existing endpoints with minimal calls).

4) UX adjustments
   - Update login page flow (password+OTP default; email code only for password-not-set).
   - Reduce typography sizes + switch to system font.
   - Add MRR box in app metrics ($390 static).

5) QA checklist
   - Verify /users/:id route works with new layout.
   - Check app metrics + overview + waitlist endpoints return data.
   - Confirm login flow works for existing and first-time admins.
