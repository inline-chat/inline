export type Listener<T> = (value: T) => void

export class Emitter<T> {
  private listeners = new Set<Listener<T>>()

  emit(value: T) {
    for (const listener of this.listeners) {
      listener(value)
    }
  }

  subscribe(listener: Listener<T>) {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }
}
