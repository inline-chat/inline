import { Elysia, t } from 'elysia';

import { eq } from 'drizzle-orm';
import { linkEmbed_experimental } from '../db/schema';
import { db } from '../db';
import { fetchLoomOembed } from '../libs/loom';

export const loomRoutes = new Elysia({ prefix: '/loom' })
  .post(
    '/',
    async ({ body, set }) => {
      const { url } = body;
      const cached = await db
        .select()
        .from(linkEmbed_experimental)
        .where(eq(linkEmbed_experimental.shareUrl, url))
        .then((result) => result[0])

      if (cached) return cached;

      const embed = await fetchLoomOembed(url);

      const [saved] = await db
        .insert(linkEmbed_experimental)
        .values({
          url: url,
          shareUrl: url,
          title: embed.title,
          imageWidth: embed.thumbnailWidth,
          imageHeight: embed.thumbnailHeight,
          html: embed.html,
          imageUrl: embed.thumbnailUrl,
          type: "loom",
          videoId: embed.videoId,
          duration: embed.duration
        })
        .returning();

      set.status = 201;
      return saved;
    },
    {
      body: t.Object({
        url: t.String({ format: 'uri', error: 'Invalid URL' }),
      }),
    },
  )
  .get(
    '/:id',
    async ({ params, set }) => {
      const record = await db
        .select()
        .from(linkEmbed_experimental)
        .where(eq(linkEmbed_experimental.id, Number(params.id)))
        .then((result) => result[0])

      if (!record) {
        set.status = 404;
        return { error: 'Not found' };
      }
      return record;
    },
    { params: t.Object({ id: t.Numeric() }) },
  );
