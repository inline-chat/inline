<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://assets-cdn.noor.to/inline/AppIcon.png" alt="Logo" width="128">
  <br>Inline
</h1>
  <p align="center">
    A thoughtfully crafted, native work chat app that just works.
  </p>
</p>

## About

Inline is the team chat app we wished existed, so we're building it ourselves. We tried Slack, Discord, iMessage, Telegram, etc but none of them felt quite right. Those are great apps so you may not need Inline now if you're already happy with your current setup. Here's what Inline is:

- **Fast**: 120-fps, instant app startup, no spinners.
- **Lightweight**: Sub-1% CPU usage, low RAM footprint.
- **Simple**: Clutter-free. Familiar concepts. Easy to use.
- **Developer-friendly**: Our API is public and designed to be very easy to use.
- **Powerful**: Feature-rich yet refreshingly well designed.
- **Organized**: Less cognitive load. Never lose a message deep in a thread.
- **Tranquil**: Stay in the flow longer by only seeing content that you need to.
- **Better notifications**: Inline can avoid distracting you when something does not require your attention.

We're currently two cofounders developing Inline full-time. Our focus is making the best app possible for small teams who use macOS and iOS primarily. We'll release our web app and Android app (in Kotlin) later this year.

> [!IMPORTANT]
> Inline is in a pre-alpha state, and only suitable for use by enthusiastic testers willing to endure an incomplete app with bugs.

## Download

- [Join the waitlist](https://inline.chat)
- Inline is not ready for production use yet.
- We give access to early testers who can help us test the app as we're building it.

## How to run this yourself

You can hack on Inline code by running it locally and connecting it to the production API.

### Add xcconfig

1. Copy `Config.xcconfig.template` to `Config.xcconfig`
2. Edit `Config.xcconfig` and make sure `USE_PRODUCTION_API` is set to `YES`
3. Run from Xcode

### Contributing

- We <3 contributions.
- Bear in mind that the project is under heavy development and we don't have a proccess for accepting contributions yet.
- Submit a [feature request](https://github.com/inline-chat/inline/discussions/new?category=ideas) or [bug report](https://github.com/inline-chat/inline/issues/new?labels=bug)

## License

Inline's macOS and iOS clients are licensed under the [GNU Affero General Public License v3.0](LICENSE).
