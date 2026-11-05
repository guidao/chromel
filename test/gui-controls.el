;;; gui-controls.el --- Interactive hint targets in Chromium -*- lexical-binding: t; -*-
(require 'chromel)
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(defvar chromel-test--source nil)
(defvar chromel-test--phase 'loading)
(defvar chromel-test--busy nil)
(defvar chromel-test--deadline (+ (float-time) 40))

(defun chromel-test--assert (value description)
  (unless value (error "%s" description)))

(defun chromel-test--finish (success description)
  (with-temp-file (getenv "CHROMEL_TEST_RESULT")
    (insert (if success "PASS: " "FAIL: ") description "\n"))
  (kill-emacs (if success 0 1)))

(defun chromel-test--until (expression description)
  (let ((deadline (+ (float-time) 3)) done)
    (while (and (not done) (< (float-time) deadline))
      (setq done (eq t (chromel--eval (concat "JSON.stringify(" expression ")"))))
      (unless done (accept-process-output nil 0.01)))
    (chromel-test--assert done description)))

(defun chromel-test--hints ()
  (chromel--eval (format "%s(\"as\",\"inspect\")" (chromel--hint-script))))

(defun chromel-test--page-focused-p ()
  (eq t (plist-get (json-parse-string (chromel--native-inspect chromel--id) :object-type 'plist) :focused)))

(defun chromel-test--scroll ()
  (chromel--eval "JSON.stringify((document.body.style.minHeight='3000px',document.documentElement.style.scrollBehavior='smooth',window.scrollTo({top:0,behavior:'instant'}),true))")
  (let ((chromel-scroll-step 60))
    (call-interactively (key-binding (kbd "j")))
    (chromel-test--until "scrollY===60" "j did not scroll the page down")
    (call-interactively (key-binding (kbd "k")))
    (chromel-test--until "scrollY===0" "k did not scroll the page up")
    (let ((current-prefix-arg 3)) (call-interactively (key-binding (kbd "j"))))
    (chromel-scroll-down)
    (chromel-scroll-down)
    (chromel-test--until "scrollY===300" "Repeated/prefixed scrolling did not accumulate")
    (chromel-test--assert (not (chromel-test--page-focused-p)) "Scrolling stole command focus")
    ;; A focused button inside an independently scrolling panel should move
    ;; that panel.  At its boundary, continue in the outer page.
    (chromel--eval "JSON.stringify((()=>{const p=document.createElement('div');p.id='scroll-panel';p.style.cssText='position:fixed;top:0;right:0;height:120px;width:200px;overflow:auto;background:white';p.innerHTML='<button>Panel action</button><div style=\"height:600px\"></div>';document.body.append(p);p.firstChild.focus({preventScroll:true});return true;})())")
    (chromel-scroll-down)
    (chromel-test--until "document.getElementById('scroll-panel').scrollTop===60 && scrollY===300"
                     "j did not prefer the focused scrollable panel")
    (chromel-scroll-up)
    (chromel-test--until "document.getElementById('scroll-panel').scrollTop===0 && scrollY===300"
                     "k did not scroll the panel up")
    (chromel-scroll-up)
    (chromel-test--until "scrollY===240" "Scrolling at a panel boundary did not reach the outer page"))
  (chromel--eval "JSON.stringify((document.getElementById('scroll-panel').remove(),document.body.style.minHeight='',document.documentElement.style.scrollBehavior='',window.scrollTo({top:0,behavior:'instant'}),true))"))

(defun chromel-test--activate (title &optional new-buffer)
  (let* ((hints (chromel-test--hints))
         (hint (cl-find title hints :key (lambda (item) (plist-get item :title)) :test #'equal)))
    (chromel-test--assert hint (format "Missing hint: %s (%S)" title hints))
    (chromel--eval (chromel--hint-call "inspect" "clear"))
    (let ((unread-command-events (string-to-list (plist-get hint :label)))
          (chromel-hint-alphabet "as"))
      (chromel-follow new-buffer))))

(defun chromel-test--controls ()
  (let* ((hints (chromel-test--hints))
         (titles (mapcar (lambda (hint) (plist-get hint :title)) hints)))
    (dolist (title '("Native button" "Role button" "Custom listener" "Tab" "Inline handler"
                     "Focusable" "Text field" "Text area" "Rich editor" "Dropdown" "Checkbox"
                     "Radio" "Hidden checkbox label" "Details" "Shadow button"
                     "Nested action" "Independent left" "Independent right"))
      (chromel-test--assert (= 1 (cl-count title titles :test #'equal)) (format "Missing/duplicate control: %s" title)))
    (dolist (title '("Disabled" "ARIA disabled" "Fieldset disabled" "Inert button" "Read only"
                     "Visible checkbox label" "Editable content" "JS listener"
                     "Button wrapper" "Button decoration" "Nested wrapper" "Two-button wrapper"
                     "Duplicate checkbox label"))
      (chromel-test--assert (not (member title titles)) (format "Unexpected hint: %s" title)))
    (chromel--eval (chromel--hint-call "inspect" "clear")))
  (chromel-test--activate "Native button")
  (chromel-test--until "state.button===1 && state.trusted && state.events.join(',')==='pointerdown,mousedown,pointerup,mouseup,click'"
                   "Native click did not deliver trusted pointer/mouse events")
  (chromel-test--assert (not (chromel-test--page-focused-p)) "Button click stole Emacs command focus")
  ;; Do not unfocus before repeating.  The next f must already be routable to
  ;; chromel-mode instead of going to the renderer and requiring C-g first.
  (chromel-test--assert (eq (key-binding (kbd "f")) #'chromel-follow) "f no longer invokes hints")
  (dolist (pair '(("Role button" . "role") ("Custom listener" . "custom") ("Tab" . "tab")
                  ("Inline handler" . "inline") ("Focusable" . "focusable") ("Shadow button" . "shadow")
                  ("Nested action" . "nested") ("Independent left" . "left") ("Independent right" . "right")))
    (chromel-test--activate (car pair))
    (chromel-test--until (format "state.%s===1" (cdr pair)) (concat "Click failed: " (car pair)))
    (chromel-test--assert (not (chromel-test--page-focused-p)) (concat "Command focus lost: " (car pair))))
  (chromel-test--activate "Checkbox")
  (chromel-test--until "document.getElementById('checkbox').checked" "Checkbox did not toggle")
  (chromel-test--activate "Radio")
  (chromel-test--until "document.getElementById('radio').checked" "Radio did not select")
  (chromel-test--activate "Hidden checkbox label")
  (chromel-test--until "document.getElementById('hidden-checkbox').checked" "Styled checkbox label failed")
  (chromel-test--activate "Details")
  (chromel-test--until "document.getElementById('details').open" "Details did not expand")
  (chromel-test--activate "Text field")
  (chromel-test--until "document.activeElement.id==='text' && document.activeElement.selectionStart===5"
                   "Text input did not receive focus/caret")
  (chromel-test--assert (chromel-test--page-focused-p) "Editable hint did not give the renderer keyboard focus")
  (dolist (pair '(("Text area" . "textarea") ("Rich editor" . "editor") ("Dropdown" . "select")))
    (chromel-test--activate (car pair))
    (chromel-test--until (format "document.activeElement.id==='%s'" (cdr pair)) (concat "Focus failed: " (car pair))))
  (chromel-test--activate "Intercepted link")
  (chromel-test--until "state.intercepted===1 && location.pathname==='/controls'" "Link bypassed preventDefault")
  (chromel-test--assert (not (chromel-test--page-focused-p)) "Link click did not restore command focus")
  (chromel-test--activate "Native button" t)
  (chromel-test--until "state.button===2" "F failed to activate button in place")
  (chromel-test--assert (eq (window-buffer (selected-window)) chromel-test--source) "F opened a buffer for a button")
  ;; DOM changes between hint collection and activation must not click a stale point.
  (let* ((hints (chromel-test--hints))
         (hint (cl-find "Disappearing" hints :key (lambda (item) (plist-get item :title)) :test #'equal)))
    (chromel--eval "JSON.stringify((document.getElementById('disappears').disabled=true))")
    (chromel-test--assert (eq :null (chromel--eval (chromel--hint-call "inspect" "prepare" (plist-get hint :label))))
                      "Disabled target was still actionable")
    (chromel--eval (chromel--hint-call "inspect" "clear")))
  (chromel-test--assert (= 0 (chromel--eval "JSON.stringify(document.querySelectorAll('[data-emacs-chromel-hints]').length)"))
                    "Hints were not cleared")
  (chromel--eval "JSON.stringify((document.getElementById('dialog').showModal(),true))")
  (let ((hints (chromel-test--hints)))
    (chromel-test--assert (= 1 (length hints)) "Hints included inert controls behind a modal dialog")
    (chromel-test--assert (eq t (chromel--eval "JSON.stringify(document.querySelector('[data-emacs-chromel-hints]').matches(':popover-open'))"))
                      "Hints were not above the modal dialog")
    (chromel--eval (chromel--hint-call "inspect" "clear")))
  (chromel-test--activate "Modal button")
  (chromel-test--until "state.modal===1 && !document.getElementById('dialog').open" "Modal button failed")
  (chromel-test--scroll)
  (chromel-test--activate "Popup button"))

(defun chromel-test--step ()
  (unless chromel-test--busy
    (let ((chromel-test--busy t))
      (with-current-buffer (window-buffer (selected-window))
        (condition-case err
            (progn
              (when (> (float-time) chromel-test--deadline) (error "Controls timed out: %s" chromel-test--phase))
              (pcase chromel-test--phase
                ('loading
                 (when (equal (buffer-local-value 'chromel--title chromel-test--source) "controls-ready")
                   (switch-to-buffer chromel-test--source)
                   (delete-other-windows)
                   (chromel--sync)
                   (chromel-test--controls)
                   (setq chromel-test--phase 'popup)))
                ((or 'popup 'blank)
                 (let ((child (window-buffer (selected-window))))
                   (when (and (not (eq child chromel-test--source))
                              (equal (buffer-local-value 'chromel--title child) "hint-target"))
                     (chromel-test--assert (not (chromel-test--page-focused-p)) "Popup stole command focus")
                     (kill-buffer child)
                     (switch-to-buffer chromel-test--source)
                     (chromel--sync)
                     (if (eq chromel-test--phase 'popup)
                         (progn (chromel-test--activate "Blank link") (setq chromel-test--phase 'blank))
                       (kill-buffer chromel-test--source)
                       (setq chromel-test--phase 'closing)))))
                ('closing
                 (when (string-match-p "Browsers including DevTools: 0" (chromel--native-info))
                   (chromel-test--finish t "Controls: j/k page and panel scrolling, command/input focus, deduplication, trusted clicks, forms, shadow DOM, SPA preventDefault, popups and cleanup")))))
          (error (chromel-test--finish nil (format "%s (phase %s)" (error-message-string err) chromel-test--phase))))))))

(run-at-time 1 nil
             (lambda ()
               (condition-case err
                   (progn
                     (set-frame-size nil 1100 750 t)
                     (setq chromel-test--source (chromel (getenv "CHROMEL_TEST_URL")))
                     (run-at-time 0.2 0.2 #'chromel-test--step))
                 (error (chromel-test--finish nil (error-message-string err))))))
