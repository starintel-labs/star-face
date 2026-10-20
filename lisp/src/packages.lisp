(defpackage :star-face
  (:use :cl)
  (:import-from :starlangruntime
                #:complete-dispatch
                #:retry-dispatch
                #:defer-dispatch)
  (:export
   #:malformed-face-result
   #:malformed-face-result-message
   #:parse-insightface-json
   #:insightface->payload
   #:face-id
   #:derive-documents
   #:*dataset*
   #:*schema-version*
   #:*storage-root*
   #:*clock-function*
   #:db-path
   #:append-document
   #:load-document
   #:scan-dtype
   #:cosine-similarity
   #:ingest-face-result
   #:search-faces
   #:face-ingest-handler
   #:face-search-handler
   #:+msg-face-result+
   #:+msg-ingest-result+
   #:+msg-search-request+
   #:+msg-search-reply+))
