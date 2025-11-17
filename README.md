<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://assets-cdn.noor.to/inline/GitHub%20Readme.png" alt="Logo" width="128" />
  <br>Inline
</h1>
  <p align="center">
    Work chat for high-performance teams.
  </p>
</p>

Inline is a fast, lightweight, scalable, and powerful work chat app which enables unprecedented collaboration bandwidth.

## What's Inline

We're designing Inline with these goals in mind.

### A place where new ideas take shape

An idea doesn't form in the issue tracker, the company wiki, or Google Docs. The earliest sparks of ideas often aren't shared. They're jotted down in private notes or mentioned in the office and then get lost. The work chat app should encourage collecting all these unpolished ideas in threads, allowing them to develop slowly with others.

### Maximum sharing

It should accommodate maximum sharing of ideas and information. Sharing less information directly impacts team alignment, collaboration, and the development of new ideas. Friction kills collective thinking. Sharing more shouldn't cause more notifications or chaos in large chats. Eventually, these small threads link and form a graph of the team's ideas, thoughts, and information.

### Highest signal-to-noise ratio

Minimum distraction—allowing you to stay in the zone for as long as possible without having to quit the app. It should be tranquil and in your control. Everything you see on the screen should matter to you; otherwise, you can close it.

### Simplicity = Flexibility = Power

A simple concept can have infinite applications— a shareable thread containing messages or more threads. You can use it to collect feedback, track bugs, review work together, write specs, brainstorm, take meeting notes, put together a team library, share assets, etc.

## How we're designing it

### Threads

Threads are the building blocks of organized and focused chats with your teammates. Seamlessly go from rapid back-and-forth to async discussions spanning days without losing track. Each thread gets a number and optionally a title for easy reference. Threads are shareable via links or by inviting users by username.

### Sidebar

The sidebar is a list of chats (threads and direct messages) you want to see at the moment. Additionally, chats that require your attention get added at the bottom (e.g., when you're explicitly mentioned in a thread). You can close any chats you don't care about at the moment. You can reopen them whenever you want. Think of it like your desktop—you only keep open the windows you need right now.

### Spaces

If you've joined 20 communities, a few friend groups, and you have your company chat, you shouldn't have to see all of those screaming in your face. Inline Spaces can be opened as tabs and closed when you don't need them anymore. Only what you care about right now.

### Home

You can use the app without being part of any team. In your Home, you can start direct messages, get invited to threads, or create them.

### Communities

We think of friend groups and communities as first-class citizens. At this point, we're primarily focused on team chat because that helps us build a sustainable business faster. The first community in the app is our own: the Town Hall.

### ... (more soon)

## Technical Details

- iOS and macOS apps are written in Swift using AppKit, UIKit, and SwiftUI.
- We aim for 120 fps, instant app startup, and low CPU and RAM usage.
- We'll have a web-based desktop app experience for Windows and Linux.
- Our Android app will start as a React Native app because of our development bandwidth.
- Our server is written in TypeScript running on Bun.
- We'll release our API docs and an SDK soon.

### Platform Support

| Platform | Status                    |
| -------- | ------------------------- |
| macOS    | Alpha, actively developed |
| iOS      | Alpha, actively developed |
| Web      | In development            |
| Android  | Not started               |
| Windows  | Not started               |
| Linux    | Not started               |

## Download

- [Join the waitlist](https://inline.chat)
- Inline is not ready for production use yet.
- We'll soon give access to early testers who can help us test the app as we're building it. Reach out if you want to be an alpha tester.

## How to run this yourself

### Running the macOS/iOS apps

You can hack on Inline macOS/iOS code (in `apple` directory) by running it locally and connecting it to the production API.

### Running the server

You need to have bun installed and a postgres database running. Create a database with the name `inline_dev` and adjust the `DATABASE_URL` in the `.env` file. You can make your `.env` file by copying the `.env.sample` file.

```bash
cd server
bun install
bun run db:migrate
bun run dev
```

### Contributing

- We <3 contributions.
- Bear in mind that the project is under heavy development and we don't have a process for accepting contributions yet.
- Submit a [feature request](https://github.com/inline-chat/inline/discussions/new?category=ideas) or [bug report](https://github.com/inline-chat/inline/issues/new?labels=bug)

## FAQ

### What stage are you at?

We currently have a closed alpha with a few teams. Our native macOS and iOS apps are in production and our web app is in development. Once those reach a stable point, we plan to ship desktop clients for Windows and Linux, and an Android app.

### Is it paid?

The app will eventually be free for individuals, communities, etc., with a paid plan for teams. However, at this time we're focused on paid teams to build a sustainable business and to work closely with early users to build what they need.

### How can you possibly build this? Many people have failed!

We have six years of experience building team communication and collaboration apps. Previously, this team co-founded [Noor](https://noor.to), a virtual office and work chat app, and we're applying those learnings to what we're building today. Time will tell, and you can be the judge when the app is released. I believe we're all better served if we get a great alternative to the current status quo, which has remained unchanged for over a decade.

### Will it have end-to-end encryption?

Short answer is not at launch. Let's go over our requirements. We want to offer the best work chat experience for teams and communities of all sizes. It has to be scalable for very large chats, stay fast and be secure at every layer.

Maximum security is end-to-end encryption which comes at a cost. For example, it makes it very difficult or impossible to sync history across devices and installs fast, securely especially across many large chats. Similarly, it impacts features like searching across all chats and file contents, AI agents, publicly sharing chat threads, real-time translation, etc. Even if it's possible to develop novel technical solutions to each of the limitations, it hasn't been done before practically in this context and it's beyond our resources as a very small startup right now.

For such reasons, we decided to instead focus on security at every layer (even encrypting the locally stored database on your iPhone or Mac similar to Signal). As we go, we'll keep exploring the options for even more security. For example, ephemeral messages or letting users selectively enable E2EE in certain chats/DMs while explicitly opting out of features like history sync or cloud search as a trade-off.

If you have suggestions, have questions or have a concern please reach out to `founders [at] inline [dot] chat`. We'll write more about how we approach security and privacy soon.

## License

Inline's macOS and iOS clients are licensed under the [GNU Affero General Public License v3.0](LICENSE).

## Thanks

Thank you for following Inline and supporting us. We'll share more on our X (Twitter) accounts and here. Please don't hesitate to reach out; if you have a question, we'll be happy to chat.
