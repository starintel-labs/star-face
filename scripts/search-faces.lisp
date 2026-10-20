;;;; Query the star-face domain over the actor protocol.
;;;; Usage: sbcl --script scripts/search-faces.lisp --embedding RESULTS.jsonl
;;;;        sbcl --script scripts/search-faces.lisp --identity PERSON_ID
;;;; --embedding picks the first face of the first envelope line as probe.

(require :asdf)

(defparameter *star-lang-src*
  (or (uiop:getenv "STAR_LANG_SRC")
      (error "STAR_LANG_SRC must point at the star-lang source tree.")))

(unless (find-package "STAR-LANG.API")
  (load (merge-pathnames "prototype/star-lang-api.lisp"
                         (pathname (concatenate 'string *star-lang-src* "/")))))

(asdf:initialize-source-registry)
(asdf:load-system :star-face)
(asdf:load-system :starlang-compiler)

(defparameter *repo-root*
  (concatenate 'string
               (string-right-trim "/"
                                  (or (uiop:getenv "STAR_FACE_ROOT")
                                      (error "STAR_FACE_ROOT must point at the star-face repository.")))
               "/"))

(defun repo-file (relative)
  (merge-pathnames relative *repo-root*))

(defun spec-cache-directory ()
  (or (uiop:getenv "STAR_FACE_CACHE_SPECS")
      (repo-file ".cache/specs/")))

(defun portable-manifest ()
  (let* ((graph (star-lang.loader:load-star-file
                 (repo-file "spec/star-face.star")
                 :cache-directory (spec-cache-directory)))
         (core-library
           (loop for node in (star-lang.loader:loaded-graph-libraries graph)
                 when (string= (star-lang.loader:library-node-name node)
                               "org.starintel/core@1")
                   return (star-lang.loader:library-node-compiled node)))
         (actors
           (list (starlangcompiler:compile-actor-file
                  (repo-file "actors/face-ingest.star"))
                 (starlangcompiler:compile-actor-file
                  (repo-file "actors/face-search.star"))))
         (root-library
          (star-lang.loader:library-node-compiled
           (star-lang.loader:loaded-graph-root graph)))
         (core-types
           (getf (starlangcompiler:emit-portable-manifest core-library '())
                 :types)))
    (let ((manifest (starlangcompiler:emit-portable-manifest root-library actors)))
      (setf (getf manifest :types)
            (append (getf manifest :types) core-types))
      manifest)))

(defun wire-value (payload key)
  (cdr (assoc key payload :test #'string=)))

(defun probe-embedding (path)
  (with-open-file (stream path)
    (loop for line = (read-line stream nil nil)
          while line
          when (plusp (length (string-trim " " line)))
            do (let* ((envelope (yason:parse line))
                      (faces (gethash "faces" envelope)))
                 (when (and faces (plusp (length faces)))
                   (return-from probe-embedding
                     (mapcar (lambda (value)
                               (let ((d (coerce value 'double-float)))
                                 (format nil "~,6F" d)))
                             (gethash "embedding" (first faces)))))))))

(defun main ()
  (let ((args (cdr sb-ext:*posix-argv*)))
    (when (uiop:getenv "STAR_FACE_DB")
      (setf star-face:*storage-root*
            (pathname (concatenate 'string
                                   (string-right-trim "/" (uiop:getenv "STAR_FACE_DB"))
                                   "/"))))
    (let ((payload
            (cond
              ((and (member "--embedding" args :test #'string=)
                    (second (member "--embedding" args :test #'string=)))
               (let ((embedding
                       (probe-embedding
                        (second (member "--embedding" args :test #'string=)))))
                 (unless embedding
                   (format *error-output* "no face embedding found in input~%")
                   (uiop:quit 2))
                 (list (cons "queryId" "cli-probe")
                       (cons "searchBy" "embedding")
                       (cons "embedding" embedding)
                       (cons "minSimilarity" "0.0000"))))
              ((and (member "--identity" args :test #'string=)
                    (second (member "--identity" args :test #'string=)))
               (list (cons "queryId" "cli-probe")
                     (cons "searchBy" "identity")
                     (cons "personRef"
                           (list (cons "schema" "starintel/person")
                                 (cons "id"
                                       (second (member "--identity" args
                                                       :test #'string=)))))))
              (t
               (format *error-output*
                       "usage: search-faces.lisp --embedding RESULTS.jsonl | --identity ID~%")
               (uiop:quit 2)))))
      (let* ((dispatcher (starlangruntime:make-deterministic-dispatcher
                          (portable-manifest)))
             (command
               (staractorprotocol:make-command-envelope
                :message-id "search-1"
                :message-type star-face:+msg-search-request+
                :actor "face-search"
                :sender "face-engine"
                :idempotency-key "cli-search-probe"
                :payload payload)))
        (starlangruntime:register-dispatch-actor
         dispatcher "face-ingest" #'star-face:face-ingest-handler)
        (starlangruntime:register-dispatch-actor
         dispatcher "face-search" #'star-face:face-search-handler)
        (starlangruntime:submit-dispatch-envelope dispatcher command)
        (starlangruntime:run-dispatcher dispatcher)
        (let ((reply
                (loop for envelope in (starlangruntime:drain-dispatcher-emitted dispatcher)
                      when (eq (getf envelope :kind) :reply)
                        return (getf envelope :payload))))
          (if reply
              (progn
                (star-face::write-json reply *standard-output*)
                (terpri))
              (progn
                (format *error-output* "no search reply~%")
                (uiop:quit 1))))))))

(main)
