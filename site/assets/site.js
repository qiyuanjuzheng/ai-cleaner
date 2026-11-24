const copy = document.querySelector("#copy-command");
const copyStatus = document.querySelector("#copy-status");
if (navigator.clipboard) {
  copy.hidden = false;
  copy.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(document.querySelector("#install-command").textContent);
      copyStatus.textContent = "命令已复制。";
    } catch {
      copyStatus.textContent = "复制失败，请选中命令后手动复制。";
    }
  });
}
