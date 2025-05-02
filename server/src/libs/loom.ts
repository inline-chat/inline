import { Log } from "../utils/log";


 interface LoomOEmbed {
  type: 'video';
  version: '1.0';
  // videoId: string;
  thumbnailHeight: number;
  thumbnailWidth: number;
  thumbnailUrl: string;
  duration: number;
  title: string;
  description?: string;
  html: string;
  height?: number;
  width?: number;
  providerName?: string;
  providerUrl?: string;
}



// To extract Loom video ID
 const loomRegex = /https?:\/\/(www\.)?loom\.com\/share\/(\w+)/;
const OEMBED_URL = 'https://www.loom.com/v1/oembed';

/**
 * Extracts video ID from a Loom URL
 * @param url The Loom share URL
 * @returns The video ID if found, null otherwise
 */
 function extractLoomVideoId(url: string): string | null {
  const match = loomRegex.exec(url);
  return match && match[2] ? match[2] : null;
}

/**
 * Validates if a URL is a valid Loom share URL
 * @param url The URL to validate
 * @returns True if valid Loom URL, false otherwise
 */
 function isValidLoomUrl(url: string): boolean {
  return loomRegex.test(url);
}

/**
 * Fetches the full oEmbed data from Loom's API
 * @param url The Loom share URL
 * @returns The full oEmbed response data
 */
export async function fetchLoomOembed(url: string): Promise<LoomOEmbed> {
  const qs = new URLSearchParams({
    url,
    format: 'json'
  });
  
  const response = await fetch(`${OEMBED_URL}?${qs}`, {
    headers: { Accept: 'application/json' },
  });
  
  if (!response.ok) {
    const errorText = await response.text().catch(() => null);
    Log.shared.error(`Loom oEmbed failed (${response.status})${errorText ? `: ${errorText}` : ''}`);
    throw new Error(`Loom oEmbed failed (${response.status})${errorText ? `: ${errorText}` : ''}`);
  }
  
  const data = await response.json();
  
  return {
    type: data.type,
    version: data.version,
    // videoId: extractLoomVideoId(url) || '',
    thumbnailHeight: data.thumbnail_height,
    thumbnailWidth: data.thumbnail_width,
    thumbnailUrl: data.thumbnail_url,
    duration: data.duration,
    title: data.title,
    description: data.description,
    html: data.html,
    height: data.height,
    width: data.width,
    providerName: data.provider_name,
    providerUrl: data.provider_url
  } as LoomOEmbed;
}
