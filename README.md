# **Winget Manager Enterprise**

Winget Manager Enterprise is a high-performance, GUI-based utility designed to streamline the management of software packages on Windows. By leveraging the Windows Package Manager (Winget) backend, this tool provides an intuitive interface for auditing, installing, updating, and uninstalling applications.

## **Core Features**

### **1\. Unified Dashboard**

* **Automated Audit:** Automatically identifies available updates for installed applications upon startup.  
* **Bulk Operations:** Supports multi-select functionality (via Ctrl or Shift clicks) to queue and apply multiple updates simultaneously, reducing downtime.  
* **Right-Click Context Menu:** Perform quick actions on selected packages directly from the dashboard view.

### **2\. Installed Applications Management**

* **Comprehensive Inventory:** Provides a searchable list of all software installed on the system that is trackable via Winget.  
* **Macro Operations:** Includes advanced "Force Reinstall" macros for troubleshooting stuck or corrupted installations (automates the uninstall-then-install sequence).  
* **Bulk Uninstallation:** Efficiently clean up multiple applications in one session.

### **3\. Asynchronous Execution Engine**

* **Zero-Freezing UI:** All Winget operations are processed via an asynchronous, non-blocking queue system. This ensures the user interface remains responsive while background tasks execute.  
* **Process Orchestration:** Each operation is handled by a background process, ensuring that long-running tasks do not hang the main thread or cause application "Not Responding" states.

### **4\. Technical Architecture**

* **Native Integration:** Built as a single-file PowerShell script utilizing WPF (System.Windows) for a modern, hardware-accelerated user experience.  
* **Event-Driven UI:** Leverages DispatcherTimer and RoutedEvents to handle updates between the background processing pipeline and the front-end dashboard.  
* **Portable Design:** Designed as a single-file utility, requiring no complex installation or registry modifications, making it ideal for portable sysadmin toolkits.

## **System Requirements**

* **OS:** Windows 10 (1809+) or Windows 11\.  
* **Dependencies:** Windows Package Manager (Winget) must be installed.  
* **Permissions:** Running with Administrative privileges is recommended for global package operations (--scope machine).

## **Usage Instructions**

1. **Launch:** Execute the script via PowerShell or double-click if configured.  
2. **Dashboard Tab:** Review the list of available updates. Select one or more packages, right-click, and select "Upgrade Selected".  
3. **Installed Apps Tab:** Search for installed software. Use context menus to uninstall or trigger a force-reinstall macro.  
4. **Monitoring:** Use the bottom status bar and overlay indicators to track the progress of queued background tasks.

## **Troubleshooting**

* **UI Locking:** The application uses an async worker queue to prevent this. If you encounter issues, ensure you are running the latest version.  
* **Package Visibility:** If an application is not appearing in the list, it may not be registered with the Winget source. Run winget list in your terminal to verify if the application is detected by the OS.

*Developed as a high-efficiency deployment utility for Windows system administration.*