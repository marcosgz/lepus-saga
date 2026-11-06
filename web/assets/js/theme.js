(function () {
  try {
    var theme = window.localStorage.getItem("lepus-saga:theme");
    if (theme === "light" || theme === "dark") document.documentElement.setAttribute("data-theme", theme);
  } catch (error) {
    document.documentElement.removeAttribute("data-theme");
  }
})();
