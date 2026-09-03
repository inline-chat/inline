"use client"

import { useEffect, useRef, useState } from "react"

import { SiteFooter, SiteHeader } from "./SiteChrome"
import { PageMarkdown } from "./components/PageMarkdown"
import { LANDING_COPY } from "./content"
import landingStoryMarkdown from "./content/story.md?raw"

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
const LANDING_STORY_MARKDOWN = landingStoryMarkdown.trim()

const LANDING_VIDEOS = [
  {
    id: "beta-announcement",
    title: LANDING_COPY.videos.betaAnnouncementTitle,
    thumbnailUrl: "https://i.ytimg.com/vi/rjb4MVZbglg/maxresdefault.jpg",
    embedUrl: "https://www.youtube-nocookie.com/embed/rjb4MVZbglg?rel=0",
    watchUrl: "https://www.youtube.com/watch?v=rjb4MVZbglg",
  },
  {
    id: "faq",
    title: LANDING_COPY.videos.qAndATitle,
    thumbnailUrl: "https://i.ytimg.com/vi/ruJnO_ty74g/maxresdefault.jpg",
    embedUrl: "https://www.youtube-nocookie.com/embed/ruJnO_ty74g?rel=0",
    watchUrl: "https://www.youtube.com/watch?v=ruJnO_ty74g",
  },
] as const

export function Landing({ isIOS }: { isIOS: boolean }) {
  const [activeSlide, setActiveSlide] = useState(0)
  const [isGalleryHovered, setIsGalleryHovered] = useState(false)
  const [activeVideo, setActiveVideo] = useState<(typeof LANDING_VIDEOS)[number] | null>(null)
  const videoDialogRef = useRef<HTMLDialogElement>(null)

  useEffect(() => {
    if (!IS_PRODUCT_GALLERY_ENABLED || isGalleryHovered) return

    const timer = window.setTimeout(() => {
      setActiveSlide((currentSlide) => (currentSlide + 1) % GALLERY_SLIDES.length)
    }, 5_000)

    return () => window.clearTimeout(timer)
  }, [activeSlide, isGalleryHovered])

  useEffect(() => {
    const dialog = videoDialogRef.current
    if (!dialog) return

    if (activeVideo && !dialog.open) {
      dialog.showModal()
      dialog.querySelector<HTMLIFrameElement>("iframe")?.focus()
    }
  }, [activeVideo])

  return (
    <main className="landing-redesign">
      <SiteHeader />

      <div className="landing-redesign__shell">
        <section className="landing-redesign__intro" aria-labelledby="landing-title">
          <h1 id="landing-title">{LANDING_COPY.headline}</h1>
          <p className="landing-redesign__summary">
            {LANDING_COPY.summaryLines[0]}{" "}
            <br />
            {LANDING_COPY.summaryLines[1]}
          </p>

          <div className="landing-redesign__actions" aria-label="Download Inline">
            <a
              className="landing-redesign__primary-action"
              href={isIOS ? IOS_TESTFLIGHT_URL : "/download/mac/beta"}
              target={isIOS ? "_blank" : undefined}
              rel={isIOS ? "noopener noreferrer" : undefined}
            >
              {isIOS ? LANDING_COPY.actions.iOS : LANDING_COPY.actions.macOS}
            </a>
            <a className="landing-redesign__secondary-action" href="/download">
              {LANDING_COPY.actions.moreDownloads} <span aria-hidden="true">→</span>
            </a>
          </div>

          <p className="landing-redesign__availability">
            {LANDING_COPY.availabilityLines[0]}{" "}
            <br />
            {LANDING_COPY.availabilityLines[1]}
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

        {LANDING_STORY_MARKDOWN ? (
          <section className="landing-redesign__story" aria-label={LANDING_COPY.story.label}>
            <PageMarkdown>{LANDING_STORY_MARKDOWN}</PageMarkdown>
          </section>
        ) : null}

        <section className="landing-redesign__videos" aria-labelledby="landing-videos-title">
          <h2 id="landing-videos-title" className="landing-redesign__visually-hidden">
            {LANDING_COPY.videos.sectionLabel}
          </h2>
          <div className="landing-redesign__video-grid">
            {LANDING_VIDEOS.map((video) => (
              <article className="landing-redesign__video-card" key={video.id}>
                <div className="landing-redesign__video-frame">
                  <button
                    className="landing-redesign__video-preview"
                    type="button"
                    aria-label={`Play ${video.title}`}
                    onClick={() => setActiveVideo(video)}
                  >
                    <img src={video.thumbnailUrl} alt="" width="1280" height="720" decoding="async" />
                    <span className="landing-redesign__video-play" aria-hidden="true">
                      <svg viewBox="0 0 24 24" fill="none">
                        <path d="m7 5 11.5 7L7 19Z" fill="currentColor" />
                      </svg>
                    </span>
                  </button>
                </div>
                <h3 className="landing-redesign__video-title">
                  <a href={video.watchUrl} target="_blank" rel="noopener noreferrer">
                    {video.title}
                  </a>
                </h3>
              </article>
            ))}
          </div>

          <dialog
            className="landing-redesign__video-dialog"
            ref={videoDialogRef}
            aria-label={activeVideo?.title ?? "Inline video"}
            onClick={(event) => {
              if (event.target === event.currentTarget) event.currentTarget.close()
            }}
            onClose={() => setActiveVideo(null)}
          >
            {activeVideo ? (
              <iframe
                src={`${activeVideo.embedUrl}&autoplay=1`}
                title={activeVideo.title}
                referrerPolicy="strict-origin-when-cross-origin"
                allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
                allowFullScreen
              />
            ) : null}
          </dialog>
        </section>
      </div>

      <SiteFooter ariaLabel="Landing footer" />
    </main>
  )
}
