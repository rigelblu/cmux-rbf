# CmuxWorkspaces

Status-group fold records are pure values. Tests need no app, AppKit, filesystem, or defaults:

```swift
import CmuxWorkspaces
import Testing

var folds = WorkspaceStatusGroupsState()
folds.toggleStatus(id: "parked")
#expect(folds.collapsedStatusIds == ["parked"])
```

The app represents an old window that has not copied its color folds with an absent record. A new window uses the open record above.
