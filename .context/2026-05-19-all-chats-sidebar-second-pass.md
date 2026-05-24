# All Chats and Sidebar Second Pass

Goal: complete the requested UI and behavior cleanup for the inbox-style sidebar and All Chats route.

Plan:

1. Sidebar row cleanup
   - Remove visual pin accessories from pinned rows.
   - Hide close controls for pinned rows.
   - Make the close control a rounded square with hover and pressed states.
   - Reduce list row spacing and make the All Chats row match chat row sizing.
   - Split pinned and normal rows with a subtle separator.

2. Sidebar behavior and data
   - Keep All Chats scoped to the currently selected space instead of selecting Home.
   - Sort inbox rows by `openedDate` ascending so newer opened rows are lower.
   - Add a lightweight observed count for unread chats in today’s section, scoped to the selected space.
   - Ensure pinned user dialogs render in a selected space when the user belongs to that space.

3. All Chats cleanup
   - Move unread count/mark to the far trailing edge of each row.
   - Prevent unread count text from truncating.
   - Use a muted unread badge color.
   - Keep preview sender names regular weight.
   - Remove the toolbar filter menu.

4. Verification
   - Add focused tests for data/query behavior where practical.
   - Run whitespace checks and focused Swift tests/builds.
   - Review the related diff for accidental unrelated changes.
