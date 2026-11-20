/**
 * Telegram -> GitHub IP inbox
 *
 * 转发 IP 消息给 bot，自动把 ip:port 追加到仓库的 shared-ips.txt。
 * 只负责收集，不测速、不碰 results.txt / pool.txt。
 */

const GITHUB_API = "https://api.github.com";

const CF_V4_CIDRS = [
  "173.245.48.0/20",
  "103.21.244.0/22",
  "103.22.200.0/22",
  "103.31.4.0/22",
  "141.101.64.0/18",
  "108.162.192.0/18",
  "190.93.240.0/20",
  "188.114.96.0/20",
  "197.234.240.0/22",
  "198.41.128.0/17",
  "162.158.0.0/15",
  "104.16.0.0/13",
  "104.24.0.0/14",
  "172.64.0.0/13",
  "131.0.72.0/22"
];

const CF_V6_CIDRS = [
  "2400:cb00::/32",
  "2606:4700::/32",
  "2803:f800::/32",
  "2405:b500::/32",
  "2405:8100::/32",
  "2a06:98c0::/29",
  "2c0f:f248::/32"
];

function v4ToInt(ip) {
  const parts = ip.split(".");
  if (parts.length !== 4) return null;
  let value = 0;
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    const n = Number(part);
    if (n > 255) return null;
    value = (value * 256) + n;
  }
  return value >>> 0;
}

function parseV4Cidr(cidr) {
  const [ip, bitsRaw] = cidr.split("/");
  const bits = Number(bitsRaw);
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
  return { base: (v4ToInt(ip) & mask) >>> 0, mask };
}

const CF_V4 = CF_V4_CIDRS.map(parseV4Cidr);

function isCloudflareV4(ip) {
  const value = v4ToInt(ip);
  if (value === null) return false;
  return CF_V4.some((net) => ((value & net.mask) >>> 0) === net.base);
}

function v6ToBigInt(ip) {
  const [head, tail] = ip.toLowerCase().split("::");
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const missing = 8 - left.length - right.length;
  if (missing < 0) return null;
  const groups = left.concat(Array(missing).fill("0"), right);
  if (groups.length !== 8) return null;
  let hex = "";
  for (const group of groups) {
    if (!/^[0-9a-f]{1,4}$/.test(group)) return null;
    hex += group.padStart(4, "0");
  }
  return BigInt("0x" + hex);
}

function parseV6Cidr(cidr) {
  const [ip, bitsRaw] = cidr.split("/");
  const bits = BigInt(bitsRaw);
  const full = (1n << 128n) - 1n;
  const mask = full ^ ((1n << (128n - bits)) - 1n);
  return { base: v6ToBigInt(ip) & mask, mask };
}

const CF_V6 = CF_V6_CIDRS.map(parseV6Cidr);

function isCloudflareV6(ip) {
  const value = v6ToBigInt(ip);
  if (value === null) return false;
  return CF_V6.some((net) => (value & net.mask) === net.base);
}

function isValidPort(port) {
  return Number.isInteger(port) && port > 0 && port <= 65535;
}

function normalizeText(text) {
  return text
    .normalize("NFKC")
    .replace(/[\u200b-\u200d\ufeff]/g, " ")
    .replace(/<[^>\n]{0,60}>/g, " ");
}

function extractFromLine(line, defaultPorts) {
  const found = [];

  for (const match of line.matchAll(/\[([0-9A-Fa-f:]{2,})\](?::(\d{1,5}))?/g)) {
    const host = match[1];
    if (v6ToBigInt(host) === null) continue;
    const port = match[2] ? Number(match[2]) : defaultPorts[0];
    if (isValidPort(port)) found.push({ host, port, v6: true });
  }

  for (const match of line.matchAll(/[0-9A-Fa-f:]{3,}/g)) {
    const token = match[0];
    const before = line[match.index - 1] || "";
    const after = line[match.index + token.length] || "";
    if (before === "[" || /[0-9A-Za-z]/.test(before) || /[0-9A-Za-z]/.test(after)) continue;
    if ((token.match(/:/g) || []).length < 2) continue;
    if (v6ToBigInt(token) === null) continue;

    const rest = line.slice(match.index + token.length);
    const portMatch = /^[\s,;|/]+(\d{1,5})(?![\d.])/.exec(rest);
    let port = null;
    if (portMatch) {
      const candidate = Number(portMatch[1]);
      if (candidate >= 100 || candidate === 80) port = candidate;
    }

    if (port === null) {
      for (const fallback of defaultPorts) {
        if (isValidPort(fallback)) found.push({ host: token, port: fallback, v6: true });
      }
    } else if (isValidPort(port)) {
      found.push({ host: token, port, v6: true });
    }
  }

  for (const match of line.matchAll(/(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.])/g)) {
    const host = match[1];
    if (v4ToInt(host) === null) continue;

    const rest = line.slice(match.index + match[0].length);
    let port = null;

    const colonPort = /^:(\d{1,5})(?!\d)/.exec(rest);
    if (colonPort) {
      port = Number(colonPort[1]);
    } else {
      const spacePort = /^[\s,;|/]+(\d{1,5})(?![\d.])/.exec(rest);
      if (spacePort) {
        const candidate = Number(spacePort[1]);
        if (candidate >= 100 || candidate === 80) port = candidate;
      }
    }

    if (port === null) {
      for (const fallback of defaultPorts) {
        if (isValidPort(fallback)) found.push({ host, port: fallback, v6: false });
      }
    } else if (isValidPort(port)) {
      found.push({ host, port, v6: false });
    }
  }

  return found;
}
function endpointKey(endpoint) {
  return `${endpoint.host.toLowerCase()}|${endpoint.port}`;
}

function formatEndpoint(endpoint) {
  return endpoint.v6
    ? `[${endpoint.host}]:${endpoint.port}`
    : `${endpoint.host}:${endpoint.port}`;
}

function extractEndpoints(text, defaultPorts = [443]) {
  const ports = defaultPorts.length ? defaultPorts : [443];
  const unique = new Map();

  for (const rawLine of normalizeText(text).split(/\r?\n/)) {
    for (const endpoint of extractFromLine(rawLine, ports)) {
      const key = endpointKey(endpoint);
      if (!unique.has(key)) unique.set(key, endpoint);
    }
  }

  return Array.from(unique.values());
}

function bytesToBase64(bytes) {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

function base64ToText(value) {
  if (!value) return "";
  const binary = atob(value.replace(/\s/g, ""));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return new TextDecoder().decode(bytes);
}

function repoPath(env) {
  return env.GH_PATH || "shared-ips.txt";
}

function branchName(env) {
  return env.GH_BRANCH || "main";
}

async function githubGet(env, path) {
  const url = `${GITHUB_API}/repos/${env.GH_REPO}/contents/${encodeURIComponent(path)}?ref=${encodeURIComponent(branchName(env))}`;
  const response = await fetch(url, {
    headers: {
      Authorization: `Bearer ${env.GH_TOKEN}`,
      Accept: "application/vnd.github+json",
      "User-Agent": "cfdata-tg-inbox"
    }
  });

  if (response.status === 404) return { text: "", sha: null };
  if (!response.ok) {
    throw new Error(`GitHub 读取失败 ${response.status}: ${await response.text()}`);
  }

  const data = await response.json();
  return { text: base64ToText(data.content), sha: data.sha };
}

async function githubPut(env, path, content, sha, message) {
  const body = {
    message,
    content: bytesToBase64(new TextEncoder().encode(content)),
    branch: branchName(env)
  };
  if (sha) body.sha = sha;

  const response = await fetch(`${GITHUB_API}/repos/${env.GH_REPO}/contents/${encodeURIComponent(path)}`, {
    method: "PUT",
    headers: {
      Authorization: `Bearer ${env.GH_TOKEN}`,
      Accept: "application/vnd.github+json",
      "Content-Type": "application/json",
      "User-Agent": "cfdata-tg-inbox"
    },
    body: JSON.stringify(body)
  });

  if (!response.ok) {
    throw new Error(`GitHub 写入失败 ${response.status}: ${await response.text()}`);
  }
}

async function reply(env, chatId, text) {
  await fetch(`https://api.telegram.org/bot${env.BOT_TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text, disable_web_page_preview: true })
  });
}

function allowedUsers(env) {
  return (env.ALLOWED_USER_IDS || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

async function handleMessage(env, message) {
  const chatId = message.chat && message.chat.id;
  const fromId = message.from && message.from.id;
  const text = message.text || message.caption || "";

  const users = allowedUsers(env);
  if (!users.length) {
    await reply(env, chatId, "未配置 ALLOWED_USER_IDS，已拒绝所有消息。");
    return;
  }
  if (!users.includes(String(fromId))) {
    await reply(env, chatId, "这个 bot 不对外使用。");
    return;
  }

  if (text.startsWith("/")) {
    const command = text.split(/\s+/)[0];
    if (command === "/id") {
      await reply(env, chatId, `你的 user id：${fromId}`);
      return;
    }
    if (command === "/stats") {
      const file = await githubGet(env, repoPath(env));
      const count = file.text.split(/\r?\n/).filter(Boolean).length;
      await reply(env, chatId, `${repoPath(env)} 当前 ${count} 条。`);
      return;
    }
    await reply(env, chatId, [
      "用法：把群里的 IP 消息转发给我即可。",
      "支持 ip:端口、ip 端口、[IPv6]:端口。",
      "/id    查看你的 Telegram user id",
      "/stats 查看已收集数量"
    ].join("\n"));
    return;
  }

  const defaultPorts = (env.DEFAULT_PORTS || "443")
    .split(",")
    .map((item) => Number(item.trim()))
    .filter((item) => Number.isInteger(item) && item > 0 && item <= 65535);
  const ports = defaultPorts.length ? defaultPorts : [443];

  const parsed = extractEndpoints(text, ports);
  if (!parsed.length) {
    await reply(env, chatId, "没找到可用 IP（格式无效或端口不对）。");
    return;
  }

  const isCF = (endpoint) => (endpoint.v6 ? isCloudflareV6(endpoint.host) : isCloudflareV4(endpoint.host));
  const cfList = parsed.filter(isCF).slice(0, 200);
  const otherList = parsed.filter((endpoint) => !isCF(endpoint)).slice(0, 200);

  const cfPath = repoPath(env);
  const otherPath = env.GH_PATH_OTHER || "shared-ips-other.txt";
  const cfResult = await mergeEndpoints(env, cfPath, cfList, ports);
  const otherResult = await mergeEndpoints(env, otherPath, otherList, ports);

  const lines = [];
  if (cfList.length) {
    lines.push(cfResult.fresh > 0
      ? `CF 段：收录 ${cfResult.fresh} 个新 IP（${cfPath}）`
      : `CF 段：这 ${cfList.length} 个都已经在 ${cfPath} 里了`);
  }
  if (otherList.length) {
    lines.push(otherResult.fresh > 0
      ? `非 CF：收录 ${otherResult.fresh} 个（${otherPath}，不参与自动测速）`
      : `非 CF：这 ${otherList.length} 个都已经在 ${otherPath} 里了`);
  }

  const sampleList = cfResult.freshList.length ? cfResult.freshList : otherResult.freshList;
  if (sampleList.length) {
    const sampleText = sampleList.slice(0, 5).map(formatEndpoint).join("\n");
    const more = sampleList.length > 5 ? `\n… 共 ${sampleList.length} 个` : "";
    lines.push(sampleText + more);
  }

  await reply(env, chatId, lines.join("\n"));
}

async function mergeEndpoints(env, path, endpoints, ports) {
  if (!endpoints.length) return { fresh: 0, freshList: [] };

  for (let attempt = 0; attempt < 2; attempt += 1) {
    const file = await githubGet(env, path);
    const existing = new Set(extractEndpoints(file.text, ports).map(endpointKey));
    const fresh = endpoints.filter((endpoint) => !existing.has(endpointKey(endpoint)));
    if (!fresh.length) return { fresh: 0, freshList: [] };

    const appended = fresh.map(formatEndpoint).join("\n") + "\n";
    const old = file.text.replace(/^\uFEFF/, "").trimEnd();
    const maxLines = Number(env.MAX_LINES || 200);
    let mergedLines = (old ? `${appended}${old}` : appended).split("\n").filter((line) => line.trim() !== "");
    if (Number.isInteger(maxLines) && maxLines > 0 && mergedLines.length > maxLines) {
      mergedLines = mergedLines.slice(0, maxLines);
    }

    try {
      await githubPut(env, path, mergedLines.join("\n") + "\n", file.sha, `tg: add ${fresh.length} ip(s)`);
      return { fresh: fresh.length, freshList: fresh };
    } catch (error) {
      if (attempt === 1) throw error;
    }
  }

  return { fresh: 0, freshList: [] };
}

export default {
  async fetch(request, env) {
    if (request.method === "GET") {
      return new Response("cfdata telegram inbox worker\n", { status: 200 });
    }
    if (request.method !== "POST") {
      return new Response("method not allowed", { status: 405 });
    }

    if (env.WEBHOOK_SECRET) {
      const token = request.headers.get("X-Telegram-Bot-Api-Secret-Token");
      if (token !== env.WEBHOOK_SECRET) {
        return new Response("forbidden", { status: 403 });
      }
    }

    let update;
    try {
      update = await request.json();
    } catch {
      return new Response("ok", { status: 200 });
    }

    const message = update.message;
    if (!message) return new Response("ok", { status: 200 });

    try {
      await handleMessage(env, message);
    } catch (error) {
      try {
        await reply(env, message.chat && message.chat.id, `处理失败：${String(error.message || error).slice(0, 300)}`);
      } catch {
        // ignore
      }
    }

    return new Response("ok", { status: 200 });
  }
};

export const __test = {
  extractEndpoints,
  extractFromLine,
  isCloudflareV4,
  isCloudflareV6,
  endpointKey,
  formatEndpoint
};