// Workers static assets answer Range requests with the whole file, but Safari
// needs 206 responses to play video. wrangler.jsonc routes only the demo videos
// through this Worker; everything else is served directly as a static asset.
export default {
  async fetch(request, env) {
    const assetHeaders = new Headers(request.headers);
    assetHeaders.delete("Range");
    assetHeaders.delete("If-Range");
    const asset = await env.ASSETS.fetch(new Request(request.url, { method: request.method, headers: assetHeaders }));

    const headers = new Headers(asset.headers);
    headers.set("Accept-Ranges", "bytes");

    const range = request.headers.get("Range");
    const ifRange = request.headers.get("If-Range");
    const rangeIsCurrent = !ifRange || ifRange === asset.headers.get("ETag");
    if (asset.status !== 200 || !range || !rangeIsCurrent) {
      return new Response(asset.body, { status: asset.status, headers });
    }

    const body = await asset.arrayBuffer();
    const size = body.byteLength;
    const match = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
    if (!match || (match[1] === "" && match[2] === "")) {
      // Unsupported forms such as multiple ranges get the whole file.
      return new Response(request.method === "HEAD" ? null : body, { status: 200, headers });
    }

    let start;
    let end;
    if (match[1] === "") {
      const suffix = Number(match[2]);
      start = Math.max(size - suffix, 0);
      end = size - 1;
      if (suffix === 0) start = size;
    } else {
      start = Number(match[1]);
      end = match[2] === "" ? size - 1 : Math.min(Number(match[2]), size - 1);
    }

    if (start >= size || start > end) {
      headers.delete("Content-Length");
      headers.set("Content-Range", `bytes */${size}`);
      return new Response(null, { status: 416, headers });
    }

    headers.set("Content-Range", `bytes ${start}-${end}/${size}`);
    headers.set("Content-Length", String(end - start + 1));
    return new Response(request.method === "HEAD" ? null : body.slice(start, end + 1), { status: 206, headers });
  },
};
