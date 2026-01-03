const TARGET_URL = "https://public-assets.inline.chat/cli/install.sh";

export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname !== "/cli/install.sh") {
      return new Response("Not found", { status: 404 });
    }

    return Response.redirect(TARGET_URL, 301);
  },
};
