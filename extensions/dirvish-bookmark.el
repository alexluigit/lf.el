;;; dirvish-bookmark.el --- Bookmark support for Dired/Dirvish -*- lexical-binding: t -*-

;; Copyright (C) 2021-2022 Alex Lu
;; Author : Alex Lu <https://github.com/alexluigit>
;; Version: 1.8.14
;; Keywords: files, convenience
;; Homepage: https://github.com/alexluigit/dirvish
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Bookmark support for Dired/Dirvish.

;;; Code:

(require 'transient)
(require 'subr-x)

(define-obsolete-variable-alias 'dirvish-menu-bookmarks 'dirvish-bookmark-entries "Jun-08,2022")
(define-obsolete-function-alias 'dirvish-bookmark-goto 'dirvish-bookmark-jump "Jul-07,2022")
;;;###autoload (autoload 'dirvish-bookmark-jump "dirvish-bookmark" nil t)
;;;###autoload (autoload 'dirvish-bookmark-goto "dirvish-bookmark" nil t)
(defcustom dirvish-bookmark-entries
  `(("h" "~/"                  "Home")
    ("e" ,user-emacs-directory "Emacs user directory"))
  "BOOKMARKs for command `dirvish-bookmark-jump'.
A BOOKMARK is a (KEY PATH DOC) alist where KEY is the key to
invoke the navigation, PATH is the the argument for command
`dired-jump', DOC (optional) is the documentation string."
  :group 'dirvish :type 'alist
  :set
  (lambda (k v)
    (set k v)
    (when-let* ((desc-len (mapcar (lambda (i) (length (nth 2 i))) v))
                (max-desc-len (seq-max desc-len)))
      (eval
       `(transient-define-prefix dirvish-bookmark-jump ()
          "Jump to Dirvish bookmarks."
          ["Go to Directory: "
           ,@(cl-loop
              for (key path desc) in v
              collect
              (list key
                    (concat desc "  "
                            (make-string (- max-desc-len (length desc)) ?\ )
                            (propertize path 'face 'font-lock-comment-face))
                    `(lambda ()
                       (interactive)
                       (dired-jump current-prefix-arg ,path))))])))))

(provide 'dirvish-bookmark)
;;; dirvish-bookmark.el ends here
