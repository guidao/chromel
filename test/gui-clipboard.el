;;; gui-clipboard.el --- Native macOS editing shortcuts -*- lexical-binding: t; -*-
(require 'chromel)
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(defvar chromel-test--source nil)
(defvar chromel-test--busy nil)
(defvar chromel-test--deadline (+ (float-time) 40))

(defun chromel-test--assert (value text) (unless value (error "%s" text)))
(defun chromel-test--js (expression) (chromel--eval (concat "JSON.stringify(" expression ")")))
(defun chromel-test--until (predicate text)
  (let ((deadline (+ (float-time) 3)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (chromel--tick)
      (accept-process-output nil 0.02))
    (chromel-test--assert (funcall predicate) text)))
(defun chromel-test--key (key) (chromel--command "test-key" key))
(defun chromel-test--copied (text)
  (chromel-test--until (lambda () (equal (gui-get-selection 'CLIPBOARD 'STRING) text))
                       (format "Command-C/X did not copy the browser selection %S (focus %s)"
                               text (chromel--native-inspect chromel--id))))
(defun chromel-test--value (text)
  (chromel-test--until (lambda () (equal (chromel-test--js "document.querySelector('input').value") text))
                       (format "Unexpected input value; expected %S" text)))
(defun chromel-test--finish (ok text)
  (with-temp-file (getenv "CHROMEL_TEST_RESULT") (insert (if ok "PASS: " "FAIL: ") text "\n"))
  (kill-emacs (if ok 0 1)))

(defun chromel-test--exercise ()
  (chromel--native-command 0 "test-clipboard-save" "")
  (unwind-protect
      (progn
        (chromel--command "test-activate")
        (chromel-focus)
        (chromel-test--until (lambda () (eq t (chromel-test--js "document.hasFocus()")))
                             "Test browser did not become active")
        (chromel-test--js "(()=>{const p=document.createElement('p');p.id='copy-text';p.textContent='Chromel 复制测试';document.body.prepend(p);const r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);return true})()")
        (chromel-test--key "s-c")
        (chromel-test--copied "Chromel 复制测试")
        (chromel-test--js "(document.querySelector('input').focus(),true)")
        (chromel-test--key "s-v")
        (chromel-test--value "Chromel 复制测试")
        (chromel-test--key "s-a")
        (chromel-test--until
         (lambda () (eq t (chromel-test--js "(()=>{const i=document.querySelector('input');return i.selectionStart===0&&i.selectionEnd===i.value.length})()")))
         "Command-A did not select the input text")
        (chromel-test--key "s-x")
        (chromel-test--value "")
        (chromel-test--copied "Chromel 复制测试")
        (chromel-test--key "s-z")
        (chromel-test--value "Chromel 复制测试")
        (chromel-test--key "s-Z")
        (chromel-test--value "")
        (chromel-test--key "s-v")
        (chromel-test--value "Chromel 复制测试")
        ;; Browser copy events must still work for custom/rich text editors.
        (chromel-test--js "(document.addEventListener('copy',e=>{e.clipboardData.setData('text/plain','custom copy');e.preventDefault()},{once:true}),true)")
        (chromel-test--key "s-c")
        (chromel-test--copied "custom copy")
        ;; Exercise a separate renderer origin and rich contenteditable text.
        (chromel-test--js "(()=>{window.childReady=false;window.childText=null;addEventListener('message',e=>{if(e.source===document.getElementById('copy-frame').contentWindow)childText=e.data});const f=document.createElement('iframe');f.id='copy-frame';f.name='clipboard-frame';f.style.cssText='position:fixed;left:0;top:200px;width:300px;height:150px;border:0;z-index:100';f.onload=()=>childReady=true;f.src=location.href.replace('127.0.0.1','localhost');document.body.append(f);return true})()")
        (chromel-test--until (lambda () (eq t (chromel-test--js "childReady"))) "Iframe did not load")
        (chromel--command "click" (chromel--json '(:x 30 :y 240 :newBuffer :false)))
        (chromel-focus)
        (chromel-test--until
         (lambda () (equal "clipboard-frame"
                           (plist-get (json-parse-string (chromel--native-inspect chromel--id)
                                                         :object-type 'plist) :focusedFrameName)))
         "Cross-origin frame did not receive focus")
        (chromel--command "javascript-focused"
                          "document.body.innerHTML='<div contenteditable id=editor><b>iframe 选区</b></div>';const editor=document.getElementById('editor');editor.focus();const range=document.createRange();range.selectNodeContents(editor);getSelection().removeAllRanges();getSelection().addRange(range);editor.addEventListener('input',()=>parent.postMessage(editor.textContent,'*'));parent.postMessage(editor.textContent,'*')")
        (chromel-test--until (lambda () (equal (chromel-test--js "childText") "iframe 选区"))
                             "Iframe editor was not ready")
        (chromel-test--key "s-x")
        (chromel-test--copied "iframe 选区")
        (chromel-test--until (lambda () (equal (chromel-test--js "childText") ""))
                             "Command-X did not cut in the iframe")
        (chromel-test--key "s-v")
        (chromel-test--until (lambda () (equal (chromel-test--js "childText") "iframe 选区"))
                             "Command-V did not paste in the iframe")
        (chromel-test--js "(()=>{const e=document.createElement('div');e.id='rich-target';e.contentEditable=true;document.body.prepend(e);e.focus();return true})()")
        (chromel-test--key "s-v")
        (chromel-test--until
         (lambda () (eq t (chromel-test--js "(()=>{const e=document.getElementById('rich-target');return e.textContent==='iframe 选区'&&Array.from(e.querySelectorAll('*')).some(x=>Number(getComputedStyle(x).fontWeight)>=700)})()")))
         "Rich text clipboard formatting was lost")
        ;; Keep a selected browser visible while the Emacs minibuffer owns input.
        (chromel--command "unfocus")
        ;; As in gui-escape.el, let the Emacs input loop consume posted keys.
        (cancel-timer chromel--timer)
        (setq chromel--timer nil)
        (let* ((map (make-sparse-keymap))
               (key (kbd "s-v"))
               (inject nil))
          (define-key map key (lambda () (interactive) (insert "Emacs paste")))
          (unwind-protect
              (minibuffer-with-setup-hook
                  (lambda ()
                    (setq inject (run-at-time 0.1 nil
                                              (lambda ()
                                                (with-current-buffer chromel-test--source
                                                  (chromel-test--key "s-v"))
                                                (run-at-time 0.2 nil #'exit-minibuffer)))))
                (chromel-test--assert (equal (read-from-minibuffer "Clipboard test: " nil map) "Emacs paste")
                                     "Browser intercepted the minibuffer shortcut"))
            (when inject (cancel-timer inject))))
        (chromel-test--value "Chromel 复制测试"))
    (chromel--native-command 0 "test-clipboard-restore" "")))

(defun chromel-test--step ()
  (unless chromel-test--busy
    (condition-case err
        (progn
          (when (> (float-time) chromel-test--deadline) (error "Clipboard test timed out"))
          (when (with-current-buffer chromel-test--source
                  (string-prefix-p "chromel-emacs-" chromel--title))
            (setq chromel-test--busy t)
            (with-current-buffer chromel-test--source (chromel-test--exercise))
            (chromel-test--finish t "Native copy/paste, select-all, cut, undo/redo, custom copy event, cross-origin iframe, rich text and Emacs minibuffer isolation")))
      (error (chromel-test--finish nil (error-message-string err))))))
(run-at-time 1 nil (lambda ()
                     (setq chromel-test--source (chromel (getenv "CHROMEL_TEST_URL")))
                     (run-at-time 0.2 0.2 #'chromel-test--step)))
