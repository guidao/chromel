;;; gui-controls.el --- Interactive hint targets in Chromium -*- lexical-binding: t; -*-
(require 'web)
(setq web-data-directory (file-name-as-directory (getenv "WEB_TEST_PROFILE")))
(defvar web-test--source nil)
(defvar web-test--phase 'loading)
(defvar web-test--busy nil)
(defvar web-test--deadline (+ (float-time) 40))

(defun web-test--assert (value description)
  (unless value (error "%s" description)))

(defun web-test--finish (success description)
  (with-temp-file (getenv "WEB_TEST_RESULT")
    (insert (if success "PASS: " "FAIL: ") description "\n"))
  (kill-emacs (if success 0 1)))

(defun web-test--until (expression description)
  (let ((deadline (+ (float-time) 3)) done)
    (while (and (not done) (< (float-time) deadline))
      (setq done (eq t (web--eval (concat "JSON.stringify(" expression ")"))))
      (unless done (accept-process-output nil 0.01)))
    (web-test--assert done description)))

(defun web-test--hints ()
  (web--eval (format "%s(\"as\",\"inspect\")" (web--hint-script))))

(defun web-test--page-focused-p ()
  (eq t (plist-get (json-parse-string (web--native-inspect web--id) :object-type 'plist) :focused)))

(defun web-test--scroll ()
  (web--eval "JSON.stringify((document.body.style.minHeight='3000px',document.documentElement.style.scrollBehavior='smooth',window.scrollTo({top:0,behavior:'instant'}),true))")
  (let ((web-scroll-step 60))
    (call-interactively (key-binding (kbd "j")))
    (web-test--until "scrollY===60" "j did not scroll the page down")
    (call-interactively (key-binding (kbd "k")))
    (web-test--until "scrollY===0" "k did not scroll the page up")
    (let ((current-prefix-arg 3)) (call-interactively (key-binding (kbd "j"))))
    (web-scroll-down)
    (web-scroll-down)
    (web-test--until "scrollY===300" "Repeated/prefixed scrolling did not accumulate")
    (web-test--assert (not (web-test--page-focused-p)) "Scrolling stole command focus")
    ;; A focused button inside an independently scrolling panel should move
    ;; that panel.  At its boundary, continue in the outer page.
    (web--eval "JSON.stringify((()=>{const p=document.createElement('div');p.id='scroll-panel';p.style.cssText='position:fixed;top:0;right:0;height:120px;width:200px;overflow:auto;background:white';p.innerHTML='<button>Panel action</button><div style=\"height:600px\"></div>';document.body.append(p);p.firstChild.focus({preventScroll:true});return true;})())")
    (web-scroll-down)
    (web-test--until "document.getElementById('scroll-panel').scrollTop===60 && scrollY===300"
                     "j did not prefer the focused scrollable panel")
    (web-scroll-up)
    (web-test--until "document.getElementById('scroll-panel').scrollTop===0 && scrollY===300"
                     "k did not scroll the panel up")
    (web-scroll-up)
    (web-test--until "scrollY===240" "Scrolling at a panel boundary did not reach the outer page"))
  (web--eval "JSON.stringify((document.getElementById('scroll-panel').remove(),document.body.style.minHeight='',document.documentElement.style.scrollBehavior='',window.scrollTo({top:0,behavior:'instant'}),true))"))

(defun web-test--activate (title &optional new-buffer)
  (let* ((hints (web-test--hints))
         (hint (cl-find title hints :key (lambda (item) (plist-get item :title)) :test #'equal)))
    (web-test--assert hint (format "Missing hint: %s (%S)" title hints))
    (web--eval (web--hint-call "inspect" "clear"))
    (let ((unread-command-events (string-to-list (plist-get hint :label)))
          (web-hint-alphabet "as"))
      (web-follow new-buffer))))

(defun web-test--controls ()
  (let* ((hints (web-test--hints))
         (titles (mapcar (lambda (hint) (plist-get hint :title)) hints)))
    (dolist (title '("Native button" "Role button" "Custom listener" "Tab" "Inline handler"
                     "Focusable" "Text field" "Text area" "Rich editor" "Dropdown" "Checkbox"
                     "Radio" "Hidden checkbox label" "Details" "Shadow button"
                     "Nested action" "Independent left" "Independent right"))
      (web-test--assert (= 1 (cl-count title titles :test #'equal)) (format "Missing/duplicate control: %s" title)))
    (dolist (title '("Disabled" "ARIA disabled" "Fieldset disabled" "Inert button" "Read only"
                     "Visible checkbox label" "Editable content" "JS listener"
                     "Button wrapper" "Button decoration" "Nested wrapper" "Two-button wrapper"
                     "Duplicate checkbox label"))
      (web-test--assert (not (member title titles)) (format "Unexpected hint: %s" title)))
    (web--eval (web--hint-call "inspect" "clear")))
  (web-test--activate "Native button")
  (web-test--until "state.button===1 && state.trusted && state.events.join(',')==='pointerdown,mousedown,pointerup,mouseup,click'"
                   "Native click did not deliver trusted pointer/mouse events")
  (web-test--assert (not (web-test--page-focused-p)) "Button click stole Emacs command focus")
  ;; Do not unfocus before repeating.  The next f must already be routable to
  ;; web-mode instead of going to the renderer and requiring C-g first.
  (web-test--assert (eq (key-binding (kbd "f")) #'web-follow) "f no longer invokes hints")
  (dolist (pair '(("Role button" . "role") ("Custom listener" . "custom") ("Tab" . "tab")
                  ("Inline handler" . "inline") ("Focusable" . "focusable") ("Shadow button" . "shadow")
                  ("Nested action" . "nested") ("Independent left" . "left") ("Independent right" . "right")))
    (web-test--activate (car pair))
    (web-test--until (format "state.%s===1" (cdr pair)) (concat "Click failed: " (car pair)))
    (web-test--assert (not (web-test--page-focused-p)) (concat "Command focus lost: " (car pair))))
  (web-test--activate "Checkbox")
  (web-test--until "document.getElementById('checkbox').checked" "Checkbox did not toggle")
  (web-test--activate "Radio")
  (web-test--until "document.getElementById('radio').checked" "Radio did not select")
  (web-test--activate "Hidden checkbox label")
  (web-test--until "document.getElementById('hidden-checkbox').checked" "Styled checkbox label failed")
  (web-test--activate "Details")
  (web-test--until "document.getElementById('details').open" "Details did not expand")
  (web-test--activate "Text field")
  (web-test--until "document.activeElement.id==='text' && document.activeElement.selectionStart===5"
                   "Text input did not receive focus/caret")
  (web-test--assert (web-test--page-focused-p) "Editable hint did not give the renderer keyboard focus")
  (dolist (pair '(("Text area" . "textarea") ("Rich editor" . "editor") ("Dropdown" . "select")))
    (web-test--activate (car pair))
    (web-test--until (format "document.activeElement.id==='%s'" (cdr pair)) (concat "Focus failed: " (car pair))))
  (web-test--activate "Intercepted link")
  (web-test--until "state.intercepted===1 && location.pathname==='/controls'" "Link bypassed preventDefault")
  (web-test--assert (not (web-test--page-focused-p)) "Link click did not restore command focus")
  (web-test--activate "Native button" t)
  (web-test--until "state.button===2" "F failed to activate button in place")
  (web-test--assert (eq (window-buffer (selected-window)) web-test--source) "F opened a buffer for a button")
  ;; DOM changes between hint collection and activation must not click a stale point.
  (let* ((hints (web-test--hints))
         (hint (cl-find "Disappearing" hints :key (lambda (item) (plist-get item :title)) :test #'equal)))
    (web--eval "JSON.stringify((document.getElementById('disappears').disabled=true))")
    (web-test--assert (eq :null (web--eval (web--hint-call "inspect" "prepare" (plist-get hint :label))))
                      "Disabled target was still actionable")
    (web--eval (web--hint-call "inspect" "clear")))
  (web-test--assert (= 0 (web--eval "JSON.stringify(document.querySelectorAll('[data-emacs-web-hints]').length)"))
                    "Hints were not cleared")
  (web--eval "JSON.stringify((document.getElementById('dialog').showModal(),true))")
  (let ((hints (web-test--hints)))
    (web-test--assert (= 1 (length hints)) "Hints included inert controls behind a modal dialog")
    (web-test--assert (eq t (web--eval "JSON.stringify(document.querySelector('[data-emacs-web-hints]').matches(':popover-open'))"))
                      "Hints were not above the modal dialog")
    (web--eval (web--hint-call "inspect" "clear")))
  (web-test--activate "Modal button")
  (web-test--until "state.modal===1 && !document.getElementById('dialog').open" "Modal button failed")
  (web-test--scroll)
  (web-test--activate "Popup button"))

(defun web-test--step ()
  (unless web-test--busy
    (let ((web-test--busy t))
      (with-current-buffer (window-buffer (selected-window))
        (condition-case err
            (progn
              (when (> (float-time) web-test--deadline) (error "Controls timed out: %s" web-test--phase))
              (pcase web-test--phase
                ('loading
                 (when (equal (buffer-local-value 'web--title web-test--source) "controls-ready")
                   (switch-to-buffer web-test--source)
                   (delete-other-windows)
                   (web--sync)
                   (web-test--controls)
                   (setq web-test--phase 'popup)))
                ((or 'popup 'blank)
                 (let ((child (window-buffer (selected-window))))
                   (when (and (not (eq child web-test--source))
                              (equal (buffer-local-value 'web--title child) "hint-target"))
                     (web-test--assert (not (web-test--page-focused-p)) "Popup stole command focus")
                     (kill-buffer child)
                     (switch-to-buffer web-test--source)
                     (web--sync)
                     (if (eq web-test--phase 'popup)
                         (progn (web-test--activate "Blank link") (setq web-test--phase 'blank))
                       (kill-buffer web-test--source)
                       (setq web-test--phase 'closing)))))
                ('closing
                 (when (string-match-p "Browsers including DevTools: 0" (web--native-info))
                   (web-test--finish t "Controls: j/k page and panel scrolling, command/input focus, deduplication, trusted clicks, forms, shadow DOM, SPA preventDefault, popups and cleanup")))))
          (error (web-test--finish nil (format "%s (phase %s)" (error-message-string err) web-test--phase))))))))

(run-at-time 1 nil
             (lambda ()
               (condition-case err
                   (progn
                     (set-frame-size nil 1100 750 t)
                     (setq web-test--source (web (getenv "WEB_TEST_URL")))
                     (run-at-time 0.2 0.2 #'web-test--step))
                 (error (web-test--finish nil (error-message-string err))))))
