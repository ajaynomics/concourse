import { Controller } from "@hotwired/stimulus"

// Rendered media, not a client-side React player. No download until the film is
// visible; reduced motion and data saving start with the complete poster story.
export default class extends Controller {
  static targets = ["video", "toggle"]

  connect() {
    this.active = true
    this.inView = false
    this.userPaused = false
    this.manualPlay = false
    this.failedSources = new Set()
    this.unavailable = !!this.videoTarget.querySelector("source[src]") && this.videoTarget.networkState === HTMLMediaElement.NETWORK_NO_SOURCE
    this.motion = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.onMotion = () => {
      this.manualPlay = false
      this.updatePlayback()
    }
    this.onVisibility = () => this.updatePlayback()
    this.onCache = () => this.videoTarget.pause()
    this.motion.addEventListener("change", this.onMotion)
    document.addEventListener("visibilitychange", this.onVisibility)
    document.addEventListener("turbo:before-cache", this.onCache)
    this.observer = new IntersectionObserver(([entry]) => {
      this.inView = entry.isIntersecting && entry.intersectionRatio >= 0.2
      this.updatePlayback()
    }, { threshold: 0.2 })
    this.observer.observe(this.videoTarget)
    this.toggleTarget.hidden = this.unavailable
    this.sync()
  }

  disconnect() {
    this.active = false
    this.observer?.disconnect()
    this.motion?.removeEventListener("change", this.onMotion)
    document.removeEventListener("visibilitychange", this.onVisibility)
    document.removeEventListener("turbo:before-cache", this.onCache)
    this.videoTarget.pause()
  }

  updatePlayback() {
    const automaticMotionBlocked = (this.motion.matches || navigator.connection?.saveData) && !this.manualPlay
    if (!this.inView || document.hidden || automaticMotionBlocked || this.userPaused) {
      this.videoTarget.pause()
    } else {
      this.play()
    }
  }

  async play() {
    if (this.unavailable) return
    const video = this.videoTarget
    if (!video.querySelector("source[src]")) {
      video.querySelectorAll("source").forEach(source => { source.src = source.dataset.src })
      video.load()
    }
    try {
      await video.play()
      if (!this.active) video.pause()
    } catch {
      // Autoplay denial leaves the poster and an explicit play action intact.
    }
    if (this.active) this.sync()
  }

  toggle() {
    if (this.videoTarget.paused) {
      this.userPaused = false
      this.manualPlay = true
      this.updatePlayback()
    } else {
      this.userPaused = true
      this.videoTarget.pause()
    }
  }

  sync() {
    const playing = !this.videoTarget.paused && this.videoTarget.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA
    this.toggleTarget.textContent = playing ? "Pause Ⅱ" : "Play ▷"
    this.toggleTarget.setAttribute("aria-label", `${playing ? "Pause" : "Play"} connection film`)
  }

  sourceFailed(event) {
    if (!event.target.hasAttribute("src")) return
    this.failedSources.add(event.target)
    // Source errors do not bubble to <video>. Keep a working second encoding,
    // but stop offering playback once every candidate has failed.
    if (this.failedSources.size === this.videoTarget.querySelectorAll("source").length) this.failed()
  }

  failed() {
    this.unavailable = true
    this.videoTarget.pause()
    this.toggleTarget.hidden = true
  }
}
