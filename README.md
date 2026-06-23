<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://assets-cdn.noor.to/inline/app-icon-medium.png" alt="Logo" width="99" />
  <br>Inline
</h1>
  <p align="center">
    Work chat for high-performance teams.
  </p>
</p>

Inline is a fast, lightweight, scalable, and powerful work chat app which enables unprecedented collaboration bandwidth.

## Download

Inline is currently invite-only. If you have access, you can use the alpha builds here:

- [Download for macOS](https://inline.chat/download/mac/beta)
- [Join the iOS TestFlight](https://testflight.apple.com/join/FkC3f7fz)
- [Join the waitlist](https://inline.chat)

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

- We aim for 120 fps, instant app startup, and low CPU and RAM usage.
- macOS and iOS are the first clients and are actively developed.
- Web, Android, Windows, and Linux support are planned as we grow.
- API docs, SDKs, bot integrations, MCP, and OpenClaw support are available for early builders.

### Platform Support

| Platform | Status                    |
| -------- | ------------------------- |
| macOS    | Alpha, actively developed |
| iOS      | Alpha, actively developed |
| Web      | Not started               |
| Android  | Not started               |
| Windows  | Not started               |
| Linux    | Not started               |

## Support the project

Inline is built by a team of two focused solely on this project since September 2024, mostly using our savings (I sold my car :)). We love building Inline in public, and we want to keep it free for most users and communities without annoying limitations while charging commercial teams.

## Builders

If you're building on top of Inline, start here:

- [Docs](https://inline.chat/docs)
- [OpenClaw setup](https://inline.chat/docs/openclaw)
- [MCP setup](https://inline.chat/docs/mcp)
- [Bot API](https://inline.chat/docs/bot-api)
- [Realtime API](https://inline.chat/docs/realtime-api)
- [CLI](cli/README.md)

### Contributing

- We are not accepting external code contributions at this time.
- The project is under heavy development and we don't have the capacity or a process for accepting contributions, especially given that LLMs have changed the dynamics here.

> [!NOTE]
> We used to have the source code for the server and native clients in this repository under AGPLv3. After agonizing over it for months, I've decided to keep the core source code closed source, at least for now, after more than a year of being open source. I may reverse this later, especially when we want to officially support self-hosting. For more, see the FAQ below. This repository now hosts the protocol, CLI, MCP server, OpenClaw plugin, SDK, and everything needed to build on top of Inline under Apache-2.0.

## FAQ

### What stage are you at?

We currently have an invite-only alpha with a few teams. Our native macOS and iOS apps are in production and our web app is in very early stages (not usable yet). Once those reach a stable point, we plan to ship desktop clients for Windows and Linux, and an Android app.

### Is it paid?

The app is free to use right now. We aim to charge teams, commercial users, and enterprise customers for a Pro plan while using that revenue to sustain development and keep Inline free for regular users.

### How can you possibly build this? Many people have failed!

We have six years of experience building team communication and collaboration apps. Previously, this team co-founded [Noor](https://noor.to), a virtual office and work chat app, and we're applying those learnings to what we're building today. Time will tell, and you can be the judge when the app is released. I believe we're all better served if we get a great alternative to the current status quo, which has remained unchanged for over a decade.

### Why did you decide to close source the server and clients?

We're a very small team, fully self-funded right now. After spending thousands of hours developing Inline, with many more ahead, there has been a constant debate in my head about whether the benefits of increased transparency from having the source open outweigh the potential risks for an early-stage startup like ours. I've open-sourced most of the apps I've worked on because I owe a lot to the open source community.

I made Inline open source mainly because I wanted people to trust it, although I always knew that without official self-hosting support, end-to-end encryption, or verifiable builds, having the source open does not necessarily serve that purpose well.

Also, external contributions aren't the same as they were before we had LLMs, which decreases their usefulness and signal-to-noise ratio significantly, especially since we're in active rapid development and things are changing very fast.

Another reason making it open source felt right was that I wanted people to build on top of Inline. For this reason, I'm publishing as much as possible under a more permissive license to allow developers to build plugins, bots, etc. using our full APIs, SDKs, and official plugins' source code.

However, if in the future I see any of the values/goals I've mentioned above taking a hit because of making those parts closed source, I will definitely reverse the decision and open source Inline again. I hope we have grown enough at that point that the risk of a bigger startup getting a head start in cloning our work is not a concern anymore.

### Will it have end-to-end encryption?

Short answer is not at launch. Let's go over our requirements. We want to offer the best work chat experience for teams and communities of all sizes. It has to be scalable for very large chats, stay fast and be secure at every layer.

Maximum security is end-to-end encryption which comes at a cost. For example, it makes it very difficult or impossible to sync history across devices and installs fast, securely especially across many large chats. Similarly, it impacts features like searching across all chats and file contents, AI agents, publicly sharing chat threads, real-time translation, etc. Even if it's possible to develop novel technical solutions to each of the limitations, it hasn't been done before practically in this context and it's beyond our resources as a very small startup right now.

For such reasons, we decided to instead focus on security at every layer (even encrypting the locally stored database on your iPhone or Mac similar to Signal). As we go, we'll keep exploring the options for even more security. For example, ephemeral messages or letting users selectively enable E2EE in certain chats/DMs while explicitly opting out of features like history sync or cloud search as a trade-off.

If you have suggestions, have questions or have a concern please reach out to `founders [at] inline [dot] chat`. We'll write more about how we approach security and privacy soon.

## License

This repository is licensed under the [Apache License 2.0](LICENSE).

## Thanks

Thank you for following Inline and supporting us. We'll share more on our X (Twitter) accounts and here. Please don't hesitate to reach out; if you have a question, we'll be happy to chat.
