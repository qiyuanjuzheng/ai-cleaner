const repository = "https://github.com/qiyuanjuzheng/ai-cleaner";
const latestRelease = "https://api.github.com/repos/qiyuanjuzheng/ai-cleaner/releases/latest";

function getDownloadLinks(release) {
  const tag = release?.tag_name;
  if (
    release?.draft !== false ||
    release.prerelease !== false ||
    !release.published_at ||
    typeof tag !== "string" ||
    !/^v\d+\.\d+\.\d+$/.test(tag) ||
    !Array.isArray(release.assets)
  ) {
    return null;
  }

  const assetBase = `${repository}/releases/download/${tag}/`;
  function uploadedAsset(name) {
    const url = assetBase + name;
    return release.assets.find((asset) =>
      asset?.name === name &&
      asset.state === "uploaded" &&
      asset.size > 0 &&
      asset.browser_download_url === url
    )?.browser_download_url;
  }

  const dmg = uploadedAsset(`AI-Cleaner-${tag}-macOS.dmg`);
  if (!dmg) return null;

  return {
    tag,
    dmg,
    zip: uploadedAsset(`AI-Cleaner-${tag}-macOS.zip`),
    checksums: uploadedAsset("SHA256SUMS.txt"),
    hasTauriUpdates: Boolean(uploadedAsset("latest.json")),
    notes: `${repository}/releases/tag/${tag}`,
  };
}

function updateReleaseStatus(message) {
  document.querySelectorAll("[data-release-status]").forEach((status) => {
    status.textContent = message;
  });
}

function showDownloadLinks({ tag, dmg, zip, checksums, hasTauriUpdates, notes }) {
  document.querySelectorAll("[data-download]").forEach((link) => {
    link.href = dmg;
    link.hidden = false;
  });
  document.querySelector("[data-download-placeholder]").hidden = true;
  updateReleaseStatus(`${tag} · DMG 通用安装包`);

  document.querySelectorAll("[data-release-notes]").forEach((link) => {
    link.href = notes;
    link.textContent = "版本说明";
  });

  if (hasTauriUpdates) {
    const link = document.querySelector("[data-platform-downloads]");
    link.href = notes;
    link.parentElement.hidden = false;
  }
  if (zip) {
    const link = document.querySelector("[data-zip]");
    link.href = zip;
    link.parentElement.hidden = false;
  }
  if (checksums) {
    const link = document.querySelector("[data-checksums]");
    link.href = checksums;
    link.parentElement.hidden = false;
  }
}

async function loadLatestDownload() {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 5000);

  try {
    const response = await fetch(latestRelease, {
      headers: { Accept: "application/vnd.github+json" },
      signal: controller.signal,
    });
    if (response.status === 404) {
      updateReleaseStatus("正式安装包尚未发布");
      return;
    }
    if (!response.ok) throw new Error(`GitHub Releases returned ${response.status}`);

    const downloadLinks = getDownloadLinks(await response.json());
    if (downloadLinks) {
      showDownloadLinks(downloadLinks);
    } else {
      updateReleaseStatus("当前正式版本未提供可用的 DMG");
    }
  } catch {
    updateReleaseStatus("暂时无法检查版本");
  } finally {
    clearTimeout(timeout);
  }
}

loadLatestDownload();

if (navigator.clipboard) {
  const copyCommand = document.querySelector("#copy-command");
  const copyStatus = document.querySelector("#copy-status");
  copyCommand.hidden = false;
  copyCommand.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(document.querySelector("#install-command").textContent);
      copyStatus.textContent = "命令已复制。";
    } catch {
      copyStatus.textContent = "复制失败，请选中命令后手动复制。";
    }
  });
}
