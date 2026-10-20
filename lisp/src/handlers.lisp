(in-package :star-face)

(defparameter +msg-face-result+ "org.starintel/star-face@1/face-result")
(defparameter +msg-ingest-result+ "org.starintel/star-face@1/ingest-result")
(defparameter +msg-search-request+ "org.starintel/star-face@1/search-request")
(defparameter +msg-search-reply+ "org.starintel/star-face@1/search-reply")

(defparameter *min-identity-similarity* 0.8d0)

(defun payload-vector->list (value)
  (cond ((vectorp value) (coerce value 'list))
        ((listp value) value)
        (t nil)))

(defun wire-face-p (value)
  (and (listp value) (assoc "faceId" value :test #'string=)))

(defun ingest-faces (payload)
  (let ((faces (payload-vector->list (wire-value payload "faces"))))
    (dolist (face faces)
      (unless (wire-face-p face)
        (fail-malformed "Every face requires a faceId.")))
    faces))

(defun ingest-face-result (payload &key (clock (funcall *clock-function*)))
  (values (derive-documents payload :clock clock)
          (ingest-faces payload)))

(defun face-ingest-handler (dispatcher command)
  (declare (ignore dispatcher))
  (handler-case
      (let ((payload (getf command :payload)))
        (multiple-value-bind (docs faces)
            (ingest-face-result payload)
          (let ((duplicates (count :duplicate (mapcar #'append-document docs))))
            (complete-dispatch
             :message-type +msg-ingest-result+
             :payload (list (cons "mediaRef" (required-wire payload "mediaRef"))
                            (cons "faceIds" (mapcar (lambda (face)
                                                      (required-wire face "faceId"))
                                                    faces))
                            (cons "documentIds" (mapcar (lambda (doc)
                                                          (cdr (assoc "_id" doc :test #'string=)))
                                                        docs))
                            (cons "duplicates" duplicates))))))
    (malformed-face-result (condition)
      (list :outcome :fail
            :code "star.face/malformed-result"
            :message (malformed-face-result-message condition)
            :retryable nil))))

(defun request-value (payload key)
  (let ((entry (assoc key payload :test #'string=)))
    (when entry (cdr entry))))

(defun request-limit (payload)
  (let ((limit (request-value payload "limit")))
    (if (and limit (>= limit 1))
        limit
        25)))

(defun request-min-similarity (payload)
  (let ((min (request-value payload "minSimilarity")))
    (if min (to-double min) 0d0)))

(defun search-candidates (&optional dataset)
  (remove-if-not
   (lambda (doc)
     (and (face-observation-p doc)
          (or (null dataset)
              (string= (cdr (assoc "dataset" doc :test #'string=))
                       dataset))))
   (scan-dtype "observation")))

(defun reference-value (doc)
  (list (cons "schema" "starintel/observation@0.9.0")
        (cons "id" (cdr (assoc "_id" doc :test #'string=)))))

(defun identity-matches (payload candidates)
  (let ((person-ref (request-value payload "personRef")))
    (unless person-ref
      (fail-malformed "Identity search requires personRef."))
    (let ((person-id (cdr (assoc "id" person-ref :test #'string=))))
      (loop for doc in candidates
            when (and (data-value doc "person_ref")
                      (string= (data-value doc "person_ref") person-id))
              collect (cons doc
                            (to-double (or (data-value doc "identity_similarity")
                                           "0.0")))))))

(defun embedding-matches (payload candidates)
  (let ((query (payload-vector->list (request-value payload "embedding"))))
    (unless query
      (fail-malformed "Embedding search requires embedding."))
    (loop for doc in candidates
          for embedding = (observation-embedding doc)
          when embedding
            collect (cons doc (cosine-similarity query embedding)))))

(defun dataset-matches (candidates)
  (mapcar (lambda (doc) (cons doc 0d0)) candidates))

(defun scored-matches (payload)
  (let ((candidates (search-candidates (request-value payload "dataset")))
        (by (request-value payload "searchBy")))
    (cond ((string= by "embedding") (embedding-matches payload candidates))
          ((string= by "identity") (identity-matches payload candidates))
          ((string= by "dataset") (dataset-matches candidates))
          (t (fail-malformed "Unknown searchBy ~A." by)))))

(defun search-faces (payload)
  (let* ((scored (sort (scored-matches payload) #'> :key #'cdr))
         (min (request-min-similarity payload))
         (limit (request-limit payload))
         (filtered (remove-if (lambda (pair) (< (cdr pair) min)) scored))
         (top (subseq filtered 0 (min limit (length filtered)))))
    top))

(defun face-search-handler (dispatcher command)
  (declare (ignore dispatcher))
  (handler-case
      (let* ((payload (getf command :payload))
             (query-id (or (request-value payload "queryId")
                           (fail-malformed "Search requires queryId.")))
             (matches (search-faces payload)))
        (if matches
            (complete-dispatch
             :message-type +msg-search-reply+
             :payload (list (cons "queryId" query-id)
                            (cons "status" "ok")
                            (cons "matches" (mapcar #'reference-value
                                                    (mapcar #'car matches)))
                            (cons "similarities" (mapcar (lambda (s) (format-decimal s 4))
                                                         (mapcar #'cdr matches)))
                            (cons "resultCount" (length matches))))
            (complete-dispatch
             :message-type +msg-search-reply+
             :payload (list (cons "queryId" query-id)
                            (cons "status" "empty")
                            (cons "resultCount" 0)))))
    (malformed-face-result (condition)
      (list :outcome :fail
            :code "star.face/malformed-search"
            :message (malformed-face-result-message condition)
            :retryable nil))))
