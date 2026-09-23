(() => {
  "use strict";

  const root = document.documentElement;
  const grid = document.getElementById("card-grid");
  const count = document.getElementById("results-count");
  const search = document.getElementById("search-input");
  const category = document.getElementById("category-filter");
  const empty = document.getElementById("empty-state");
  const reset = document.getElementById("reset-filters");
  const toggle = document.getElementById("theme-toggle");
  const storageKey = "apliarte-showcase-theme";
  let apps = [];

  function setTheme(theme) {
    const dark = theme === "dark";
    root.dataset.theme = dark ? "dark" : "light";
    toggle.setAttribute("aria-pressed", String(dark));
    toggle.setAttribute("aria-label", dark ? "Activar modo claro" : "Activar modo oscuro");
    document.querySelector('meta[name="theme-color"]').content = dark ? "#131d27" : "#f7fafc";
  }

  try { setTheme(localStorage.getItem(storageKey)); } catch { setTheme("light"); }
  toggle.addEventListener("click", () => {
    const next = root.dataset.theme === "dark" ? "light" : "dark";
    setTheme(next);
    try { localStorage.setItem(storageKey, next); } catch { /* Storage may be disabled. */ }
  });

  function normalise(value) {
    return String(value).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLocaleLowerCase("es");
  }

  function safeLink(url) {
    try {
      const parsed = new URL(url);
      return parsed.protocol === "https:" ? parsed.href : null;
    } catch { return null; }
  }

  function link(label, url, className) {
    const anchor = document.createElement("a");
    anchor.textContent = `${label} ↗`;
    anchor.href = url;
    anchor.className = className;
    anchor.target = "_blank";
    anchor.rel = "noopener noreferrer";
    return anchor;
  }

  function card(app, index) {
    const article = document.createElement("article");
    article.className = "app-card";
    const top = document.createElement("div");
    top.className = "card-top";
    const symbol = document.createElement("span");
    symbol.className = "card-symbol";
    symbol.setAttribute("aria-hidden", "true");
    symbol.textContent = ["✳", "▧", "?", "◈", "◎"][index % 5];
    const number = document.createElement("span");
    number.className = "card-index";
    number.textContent = String(index + 1).padStart(2, "0");
    top.append(symbol, number);

    const kind = document.createElement("p");
    kind.className = "card-category";
    kind.textContent = app.category;
    const title = document.createElement("h3");
    title.textContent = app.title;
    const description = document.createElement("p");
    description.className = "card-description";
    description.textContent = app.description;
    const tags = document.createElement("div");
    tags.className = "card-tags";
    tags.setAttribute("aria-label", "Tecnologías");
    app.tags.forEach(tag => {
      const item = document.createElement("span");
      item.textContent = tag;
      tags.append(item);
    });
    const links = document.createElement("div");
    links.className = "card-links";
    links.append(link("Abrir app", app.liveUrl, "card-live"));
    const divider = document.createElement("span");
    divider.className = "divider";
    divider.setAttribute("aria-hidden", "true");
    links.append(divider, link("Ver código", app.repoUrl, "card-repo"));
    article.append(top, kind, title, description, tags, links);
    return article;
  }

  function render() {
    const query = normalise(search.value.trim());
    const selected = category.value;
    const visible = apps.filter(app => (selected === "all" || app.category === selected) &&
      normalise([app.title, app.description, app.category, ...app.tags].join(" ")).includes(query));
    grid.replaceChildren(...visible.map(card));
    empty.hidden = visible.length !== 0;
    count.textContent = `${visible.length} ${visible.length === 1 ? "proyecto" : "proyectos"}${visible.length !== apps.length ? ` de ${apps.length}` : ""}`;
  }

  search.addEventListener("input", render);
  category.addEventListener("change", render);
  reset.addEventListener("click", () => { search.value = ""; category.value = "all"; render(); search.focus(); });
  document.addEventListener("keydown", event => {
    if (event.key === "/" && !event.altKey && !event.ctrlKey && !event.metaKey &&
        !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)) {
      event.preventDefault(); search.focus();
    }
  });

  fetch("webapps.json")
    .then(response => { if (!response.ok) throw new Error(`HTTP ${response.status}`); return response.json(); })
    .then(data => {
      if (!Array.isArray(data)) throw new Error("El catálogo no es una lista");
      apps = data.filter(app => app && typeof app.title === "string" && typeof app.description === "string" &&
        typeof app.category === "string" && Array.isArray(app.tags) && app.tags.every(tag => typeof tag === "string") &&
        safeLink(app.liveUrl) && safeLink(app.repoUrl));
      if (!apps.length) throw new Error("El catálogo está vacío");
      [...new Set(apps.map(app => app.category))].sort((a, b) => a.localeCompare(b, "es")).forEach(name => {
        const option = document.createElement("option");
        option.value = name;
        option.textContent = name;
        category.append(option);
      });
      render();
    })
    .catch(() => {
      count.textContent = "No se pudo cargar el catálogo.";
      empty.hidden = false;
      empty.querySelector("h3").textContent = "El catálogo no está disponible";
      empty.querySelector("p").textContent = "Recarga la página o vuelve a intentarlo más tarde.";
      reset.hidden = true;
    });
})();
