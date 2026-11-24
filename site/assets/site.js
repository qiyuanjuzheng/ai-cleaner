const scan = document.querySelector("#demo-scan");
const select = document.querySelector("#demo-select");
const trash = document.querySelector("#demo-trash");
const status = document.querySelector("#demo-status");
const empty = document.querySelector("#demo-empty");
const confirm = document.querySelector("#demo-confirm");
const confirmDetail = document.querySelector("#demo-confirm-detail");

const entries = Array.from(document.querySelectorAll(".demo-items input"), input => ({
  input,
  row: input.closest("li"),
  size: Number(input.dataset.mb),
  tier: input.dataset.tier,
}));

function total(items) {
  return items.reduce((size, entry) => size + entry.size, 0);
}

function formatSize(size) {
  return size >= 1000 ? (size / 1000).toFixed(2) + " GB" : size + " MB";
}

function availableEntries() {
  return entries.filter(entry => !entry.row.hidden);
}

function checkedEntries() {
  return availableEntries().filter(entry => entry.input.checked);
}

function updateDemo(message) {
  const available = availableEntries();
  const checked = checkedEntries();

  for (const tier of ["recommended", "review"]) {
    const size = total(available.filter(entry => entry.tier === tier));
    document.querySelector("#demo-" + tier + "-size").textContent = formatSize(size);
    const segment = document.querySelector(".meter-" + tier);
    segment.hidden = size === 0;
    segment.style.setProperty("--weight", size);
  }

  empty.hidden = available.length > 0;
  select.disabled = !available.some(entry => entry.tier === "recommended" && !entry.input.checked);
  trash.disabled = checked.length === 0;

  if (message) {
    status.textContent = message;
  } else if (checked.length) {
    status.textContent = "已选 " + checked.length + " 项 · " + formatSize(total(checked));
  } else {
    status.textContent = "扫描到 " + (available.length + 1) + " 项";
  }
}

for (const entry of entries) {
  entry.input.disabled = false;
  entry.input.addEventListener("change", () => updateDemo());
}

scan.disabled = false;
scan.addEventListener("click", () => {
  for (const entry of entries) {
    entry.row.hidden = false;
    entry.input.checked = false;
  }
  updateDemo("示例扫描完成 · 找到 4 项");
});

select.addEventListener("click", () => {
  for (const entry of availableEntries()) {
    if (entry.tier === "recommended") entry.input.checked = true;
  }
  updateDemo();
});

trash.addEventListener("click", () => {
  const checked = checkedEntries();
  confirmDetail.textContent = "本次将模拟移入 " + checked.length + " 项（" + formatSize(total(checked)) + "）。";
  confirm.returnValue = "cancel";
  confirm.showModal();
});

confirm.addEventListener("close", () => {
  if (confirm.returnValue !== "trash") return;
  const checked = checkedEntries();
  for (const entry of checked) {
    entry.input.checked = false;
    entry.row.hidden = true;
  }
  updateDemo("已模拟移入废纸篓 · " + checked.length + " 项 · " + formatSize(total(checked)));
  scan.focus();
});

updateDemo();

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
