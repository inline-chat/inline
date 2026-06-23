const colorCodes = {
  blue: "\x1b[34m",
  cyan: "\x1b[36m",
  dim: "\x1b[2m",
  green: "\x1b[32m",
  red: "\x1b[31m",
  reset: "\x1b[0m",
  yellow: "\x1b[33m",
} as const;

type Color = keyof typeof colorCodes;

export class ReleaseLog {
  private readonly useColor =
    process.stdout.isTTY && !process.env.NO_COLOR && process.env.TERM !== "dumb";

  heading(title: string) {
    console.log("");
    console.log(this.color(`== ${title}`, "cyan"));
  }

  step(title: string) {
    console.log(this.color(`> ${title}`, "blue"));
  }

  info(message: string) {
    console.log(`  ${message}`);
  }

  ok(message: string) {
    console.log(`${this.color("[ok]", "green")} ${message}`);
  }

  skip(message: string) {
    console.log(`${this.color("[skip]", "dim")} ${message}`);
  }

  warn(message: string) {
    console.warn(`${this.color("[warn]", "yellow")} ${message}`);
  }

  error(message: string) {
    console.error(`${this.color("[error]", "red")} ${message}`);
  }

  command(command: string) {
    console.log(`${this.color("$", "dim")} ${command}`);
  }

  status(title: string, rows: Array<{ label: string; value: string }>) {
    this.heading(title);
    const width = Math.max(...rows.map((row) => row.label.length), 0);
    for (const row of rows) {
      console.log(
        `  ${this.color(row.label.padEnd(width), "dim")}  ${row.value}`,
      );
    }
  }

  private color(value: string, color: Color) {
    if (!this.useColor) return value;
    return `${colorCodes[color]}${value}${colorCodes.reset}`;
  }
}

export function formatMs(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  const seconds = Math.round(ms / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  return rest > 0 ? `${minutes}m ${rest}s` : `${minutes}m`;
}
