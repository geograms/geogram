Let's work on the Alerts app. Here is the related documentation to know:

/home/brito/code/geograms/geogram-desktop/docs/API.md
/home/brito/code/geograms/geogram-desktop/docs/data-transmission.md
/home/brito/code/geograms/geogram-desktop/docs/apps/alert-format-specification.md
  
There is a test that was supposed to verify that photo uploads attached to alerts should work:
/home/brito/code/geograms/geogram-desktop/tests/app_alert_test.dart

It passes all tests but the folder structure is different in each one of them and this is breaking the correct synchronization between them. Below are the tree results from the different devices.

-----------------------

Client A, author of the alert:

brito@x390:/tmp/geogram-alert-clientA/devices/X19Y3E/alerts$ tree
.
├── active
│   └── 38.7_-9.1
│       └── 38_7223_n9_1393_test-alert-with-photos
│           ├── comments
│           │   └── 1765743323215.txt
│           ├── photo_2.png
│           ├── report.txt
│           └── test_photo.png
├── collection.js
└── extra
    ├── security.json
    └── tree.json
        
-----------------------

Test station server:

brito@x390:/tmp/geogram-alert-station/devices/X19Y3E$ tree
.
└── alerts
    └── 38_7223_n9_1393_test-alert-with-photos
        ├── comments
        │   └── 1765743323215.txt
        ├── photo_2.png
        ├── report.txt
        └── test_photo.png

-----------------------

Client B synchronizing to the alert:

brito@x390:/tmp/geogram-alert-clientB/devices/X19Y3E/alerts$ tree
.
└── 38_7223_n9_1393_test-alert-with-photos
    ├── comments
    │   └── 2025-12-14_21-15-23_X13K0G.txt
    ├── photo_2.png
    ├── report.txt
    └── test_photo.png

-----------------------

Look at some of the differences:
+ different folder structure
+ different file names for comments

Let's simplify the structure, don't make changes yet on the documentation. Let's first experiment on the code and results until they are satisfactory:

1) preserve the scheme of "active" and "expired" folders and make sure that all parties (clientA, clientB and station) use the same folder structure

2) Photos attached to the Alert by the author stay in a subfolder "images" inside the folder for that aler, they need to be renamed as photo{number}.{extension} where {number} is the count of pictures on the folder and {extension} is the original extension. This is necessary to avoid leaking sensitive information as filenames. There is some implementation inside the code that places the photos inside an "images" folder, please remove that situation so that the file structure is the same for everyone

3) change from "38_7223_n9_1393_test-alert-with-photos" to the folder structure "2025-12-14_15-32_test-alert-with-photos" to replace the coordinates on the folder name with the timestamp. The parent folder should be "38.7_-9.1" and this is already good as filter to make sure we don't get too many files per each folder (max is 30 000 files).

4) subfolders: both the station server and client B MUST ALWAYS follow the same structure as created by client A.

