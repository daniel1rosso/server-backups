(() => {
  const ACTION_LABELS = {
    backup: {
      loadingText: "Lanzando backup...",
      loadingMessage: "Orbix está lanzando el backup.",
    },
    restore: {
      loadingText: "Lanzando restore...",
      loadingMessage: "Orbix está encolando el restore.",
    },
    logs: {
      loadingText: "Buscando logs...",
      loadingMessage: "Orbix está consultando logs y validando el origen.",
    },
    settings: {
      loadingText: "Guardando...",
      loadingMessage: "Orbix está guardando la configuración.",
    },
    notifications: {
      loadingText: "Guardando...",
      loadingMessage: "Orbix está guardando las notificaciones.",
    },
    doctor: {
      loadingText: "Lanzando diagnóstico...",
      loadingMessage: "Orbix está lanzando una acción de mantenimiento.",
    },
    ssh: {
      loadingText: "Probando SSH...",
      loadingMessage: "Orbix está lanzando la validación SSH.",
    },
    telegram: {
      loadingText: "Enviando prueba...",
      loadingMessage: "Orbix está enviando la prueba de Telegram.",
    },
    disk: {
      loadingText: "Chequeando disco...",
      loadingMessage: "Orbix está lanzando el chequeo de disco.",
    },
    resource: {
      loadingText: "Chequeando CPU/RAM...",
      loadingMessage: "Orbix está lanzando el escaneo de CPU y RAM.",
    },
    server: {
      loadingText: "Guardando server...",
      loadingMessage: "Orbix está guardando la configuración del server.",
    },
    "server-create": {
      loadingText: "Creando server...",
      loadingMessage: "Orbix está creando el nuevo server.",
    },
  };

  const measureExpandedHeight = (body) => {
    const clone = body.cloneNode(true);
    clone.style.position = "absolute";
    clone.style.visibility = "hidden";
    clone.style.pointerEvents = "none";
    clone.style.height = "auto";
    clone.style.maxHeight = "none";
    clone.style.overflow = "visible";
    clone.style.display = "block";
    clone.style.webkitLineClamp = "unset";
    clone.style.setProperty("-webkit-line-clamp", "unset");
    clone.style.whiteSpace = body.classList.contains("is-preformatted") ? "pre-wrap" : "normal";
    clone.style.width = `${body.clientWidth || body.offsetWidth || body.getBoundingClientRect().width}px`;
    document.body.appendChild(clone);
    const height = clone.scrollHeight;
    clone.remove();
    return height;
  };

  const initCollapsibles = (scope = document) => {
    const roots = scope.querySelectorAll("[data-collapsible]");
    roots.forEach((root) => {
      if (!(root instanceof HTMLElement) || root.dataset.collapsibleBound === "true") return;
      const body = root.querySelector("[data-collapsible-body]");
      const button = root.querySelector("[data-collapsible-toggle]");
      if (!(body instanceof HTMLElement) || !(button instanceof HTMLButtonElement)) return;

      root.dataset.collapsibleBound = "true";
      const lines = Number(root.getAttribute("data-lines") || "5");
      root.style.setProperty("--collapsible-lines", String(lines));

      const refresh = () => {
        const expanded = root.classList.contains("is-expanded");
        root.classList.remove("is-ready");
        body.style.removeProperty("max-height");
        const lineHeight = Number.parseFloat(window.getComputedStyle(body).lineHeight) || 24;
        const expandedHeight = measureExpandedHeight(body);
        const collapsedHeight = Math.ceil(lineHeight * lines + 6);
        const shouldCollapse = expandedHeight - collapsedHeight > lineHeight * 0.8;

        root.classList.toggle("is-collapsible", shouldCollapse);
        body.style.maxHeight = shouldCollapse && !expanded ? `${collapsedHeight}px` : "";
        button.hidden = !shouldCollapse;
        if (!shouldCollapse) {
          root.classList.remove("is-expanded");
          button.setAttribute("aria-expanded", "false");
          button.textContent = "Ver más";
        } else if (expanded) {
          button.setAttribute("aria-expanded", "true");
          button.textContent = "Ver menos";
        } else {
          button.setAttribute("aria-expanded", "false");
          button.textContent = "Ver más";
        }
        root.classList.add("is-ready");
      };

      button.addEventListener("click", () => {
        const expanded = root.classList.toggle("is-expanded");
        button.setAttribute("aria-expanded", String(expanded));
        button.textContent = expanded ? "Ver menos" : "Ver más";
        body.style.maxHeight = expanded ? "" : `${Math.ceil((Number.parseFloat(window.getComputedStyle(body).lineHeight) || 24) * lines + 6)}px`;
      });

      if ("ResizeObserver" in window) {
        const observer = new ResizeObserver(refresh);
        observer.observe(body);
      }

      refresh();
      window.addEventListener("load", refresh, { once: true });
    });
  };

  const initDisclosures = (scope = document) => {
    const buttons = scope.querySelectorAll("[data-disclosure-toggle]");
    buttons.forEach((button) => {
      if (!(button instanceof HTMLButtonElement) || button.dataset.disclosureBound === "true") return;
      const targetId = button.getAttribute("data-disclosure-toggle");
      if (!targetId) return;
      const target = document.getElementById(targetId);
      if (!(target instanceof HTMLElement)) return;

      button.dataset.disclosureBound = "true";
      const collapsedLabel = button.getAttribute("data-label-collapsed") || "Ver más";
      const expandedLabel = button.getAttribute("data-label-expanded") || "Ver menos";

      const sync = () => {
        const expanded = !target.hidden;
        button.setAttribute("aria-expanded", String(expanded));
        button.textContent = expanded ? expandedLabel : collapsedLabel;
      };

      button.addEventListener("click", () => {
        target.hidden = !target.hidden;
        sync();
      });

      sync();
    });
  };

  const initModals = (scope = document) => {
    const openers = scope.querySelectorAll("[data-modal-open]");
    openers.forEach((opener) => {
      if (!(opener instanceof HTMLButtonElement) || opener.dataset.modalBound === "true") return;
      const targetId = opener.getAttribute("data-modal-open");
      if (!targetId) return;
      const dialog = document.getElementById(targetId);
      if (!(dialog instanceof HTMLDialogElement)) return;

      opener.dataset.modalBound = "true";
      opener.addEventListener("click", () => dialog.showModal());

      dialog.querySelectorAll("[data-modal-close]").forEach((closer) => {
        if (!(closer instanceof HTMLButtonElement) || closer.dataset.modalBound === "true") return;
        closer.dataset.modalBound = "true";
        closer.addEventListener("click", () => dialog.close());
      });

      dialog.addEventListener("click", (event) => {
        const rect = dialog.getBoundingClientRect();
        const inside =
          rect.top <= event.clientY &&
          event.clientY <= rect.top + rect.height &&
          rect.left <= event.clientX &&
          event.clientX <= rect.left + rect.width;
        if (!inside) dialog.close();
      });
    });
  };

  const initLoading = (scope = document) => {
    scope.querySelectorAll("form").forEach((form) => {
      if (!(form instanceof HTMLFormElement) || form.dataset.loadingBound === "true") return;
      form.dataset.loadingBound = "true";
      form.addEventListener("submit", () => {
        const action = form.getAttribute("action") || "";
        const asyncAction = action.startsWith("/actions/");
        const kind = form.dataset.actionKind || "";
        const labels = ACTION_LABELS[kind] || null;
        if (form.dataset.skipLoading === "true") return;
        form.classList.add("is-submitting");

        const statusEl = form.querySelector("[data-loading-status]");
        if (statusEl instanceof HTMLElement) {
          statusEl.hidden = false;
          statusEl.textContent = asyncAction
            ? form.dataset.asyncLoadingMessage || labels?.loadingMessage || "Orbix está lanzando la acción..."
            : form.dataset.loadingMessage || labels?.loadingMessage || "Orbix está procesando la solicitud...";
        }

        form.querySelectorAll('button[type="submit"]').forEach((button) => {
          if (!(button instanceof HTMLButtonElement)) return;
          if (!button.dataset.originalText) {
            button.dataset.originalText = button.textContent || "";
          }
          button.disabled = true;
          button.classList.add("is-loading");
          button.setAttribute("aria-busy", "true");
          button.textContent = asyncAction
            ? form.dataset.asyncLoadingText || button.dataset.asyncText || labels?.loadingText || "Lanzando..."
            : form.dataset.loadingText || labels?.loadingText || "Cargando...";
        });
      });
    });
  };

  const shell = document.querySelector("[data-app-shell]");
  const navToggle = document.querySelector("[data-nav-toggle]");
  const navClose = document.querySelector("[data-nav-close]");

  const closeNav = () => {
    shell?.classList.remove("nav-open");
    navToggle?.setAttribute("aria-expanded", "false");
  };

  navToggle?.addEventListener("click", () => {
    const next = !shell?.classList.contains("nav-open");
    shell?.classList.toggle("nav-open", next);
    navToggle.setAttribute("aria-expanded", String(next));
  });

  navClose?.addEventListener("click", closeNav);

  document.addEventListener("click", (event) => {
    if (!shell?.classList.contains("nav-open")) return;
    const target = event.target;
    if (!(target instanceof HTMLElement)) return;
    if (target.closest(".sidebar") || target.closest("[data-nav-toggle]")) return;
    closeNav();
  });

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") closeNav();
  });

  window.OrbixUI = {
    initCollapsibles,
    initDisclosures,
    initModals,
    initLoading,
  };

  initCollapsibles();
  initDisclosures();
  initModals();
  initLoading();
})();
