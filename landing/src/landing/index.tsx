"use client"

import { useEffect, useState } from "react"

import { SiteFooter, SiteHeader } from "./SiteChrome"

const GALLERY_SLIDES = [
  {
    id: "message-style",
    label: "Discussing message styles",
    src: "/inline-macos-message-style.webp",
    width: 2169,
    height: 1537,
    imageClassName: "landing-redesign__product-image--workspace",
  },
  {
    id: "compose",
    label: "Composing a message",
    src: "/inline-macos-compose.webp",
    width: 2239,
    height: 1475,
    imageClassName: "landing-redesign__product-image--screenshot",
  },
  {
    id: "workspace",
    label: "Workspace overview",
    src: "/inline-macos-codex.webp",
    width: 2265,
    height: 1542,
    imageClassName: "landing-redesign__product-image--workspace",
  },
  {
    id: "sentry-report",
    label: "Reviewing a Sentry report",
    src: "/inline-macos-sentry-report.webp",
    width: 1123,
    height: 768,
    imageClassName: "landing-redesign__product-image--workspace",
  },
] as const

const IS_PRODUCT_GALLERY_ENABLED = true
const IOS_TESTFLIGHT_URL = "https://testflight.apple.com/join/FkC3f7fz"

export function Landing({ isIOS }: { isIOS: boolean }) {
  const [activeSlide, setActiveSlide] = useState(0)
  const [isGalleryHovered, setIsGalleryHovered] = useState(false)

  useEffect(() => {
    if (!IS_PRODUCT_GALLERY_ENABLED || isGalleryHovered) return

    const timer = window.setTimeout(() => {
      setActiveSlide((currentSlide) => (currentSlide + 1) % GALLERY_SLIDES.length)
    }, 5_000)

    return () => window.clearTimeout(timer)
  }, [activeSlide, isGalleryHovered])

  return (
    <main className="landing-redesign">
      <SiteHeader />

      <div className="landing-redesign__shell">
        <section className="landing-redesign__intro" aria-labelledby="landing-title">
          <h1 id="landing-title">The interface for multiplayer work</h1>
          <p className="landing-redesign__summary">
            Inline is a thread-based chat app for all work,{" "}
            <br />
            with your teammates and agents.
          </p>

          <div className="landing-redesign__actions" aria-label="Download Inline">
            <a
              className="landing-redesign__primary-action"
              href={isIOS ? IOS_TESTFLIGHT_URL : "/download/mac/beta"}
              target={isIOS ? "_blank" : undefined}
              rel={isIOS ? "noopener noreferrer" : undefined}
            >
              {isIOS ? "Join iOS TestFlight" : "Download for macOS"}
            </a>
            <a className="landing-redesign__secondary-action" href="/download">
              More downloads <span aria-hidden="true">→</span>
            </a>
          </div>

          <p className="landing-redesign__availability">
            Available in beta for macOS and iOS, other platforms{" "}
            <br />
            coming soon. CLI, MCP, agent plugins, available.
          </p>
        </section>

        <section
          className="landing-redesign__product"
          aria-label={IS_PRODUCT_GALLERY_ENABLED ? "Inline product gallery" : "Inline product preview"}
          aria-roledescription={IS_PRODUCT_GALLERY_ENABLED ? "carousel" : undefined}
          onMouseEnter={() => setIsGalleryHovered(true)}
          onMouseLeave={() => setIsGalleryHovered(false)}
        >
          <div className="landing-redesign__product-frame">
            <div className="landing-redesign__product-track">
              {(IS_PRODUCT_GALLERY_ENABLED ? GALLERY_SLIDES : GALLERY_SLIDES.slice(0, 1)).map((slide, index) => (
                <figure
                  className={`landing-redesign__product-slide${
                    activeSlide === index ? " landing-redesign__product-slide--active" : ""
                  }`}
                  key={slide.id}
                  aria-hidden={activeSlide !== index}
                >
                  <img
                    className={`landing-redesign__product-image ${slide.imageClassName}`}
                    src={slide.src}
                    alt={`Inline for macOS — ${slide.label}`}
                    width={slide.width}
                    height={slide.height}
                    fetchPriority={index === 0 ? "high" : "auto"}
                  />
                </figure>
              ))}
            </div>
          </div>

          {IS_PRODUCT_GALLERY_ENABLED ? (
            <>
              <div className="landing-redesign__pagination" aria-label="Choose a product view">
                {GALLERY_SLIDES.map((slide, index) => (
                  <button
                    className={`landing-redesign__pagination-dot${
                      activeSlide === index ? " landing-redesign__pagination-dot--active" : ""
                    }`}
                    type="button"
                    key={slide.id}
                    aria-label={`Show ${slide.label}`}
                    aria-pressed={activeSlide === index}
                    onClick={() => setActiveSlide(index)}
                  />
                ))}
              </div>
              <p className="landing-redesign__visually-hidden" aria-live="polite">
                {GALLERY_SLIDES[activeSlide].label}
              </p>
            </>
          ) : null}
        </section>

        {/* Temporarily hidden until the replacement story copy is ready.
        <section className="landing-redesign__story" aria-labelledby="landing-story-title">
          <h2 id="landing-story-title" className="landing-redesign__visually-hidden">
            Why we built Inline
          </h2>
          <p>We started building chat apps for ourselves when we could not stand the decade-old, bloated Slack.</p>
          <p>
            While using the app, we started asking ourselves questions like “why not make reply threads also be like normal
            chats?” and questioned the status quo in those apps. Hundreds of iterations later, I had felt the magic of
            threads and could not forget it.
          </p>
          <p>
            I started Inline to create the best chat app for all kinds of work. Turns out when you nail the design for human
            collaboration, you also make the best interface for agents.
          </p>
        </section>
        */}
      </div>

      <SiteFooter ariaLabel="Landing footer" />
    </main>
  )
}
