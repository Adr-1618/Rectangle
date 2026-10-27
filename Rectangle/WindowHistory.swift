/// WindowHistory.swift

import Foundation

class WindowHistory {
    
    var restoreRects = [CGWindowID: CGRect]() // the last window frame that the user positioned
    
    var lastRectangleActions = [CGWindowID: RectangleAction]() // the last window frame that this app positioned
    
    var preMaximizeRects = [CGWindowID: CGRect]() // the normalized window frame right before this app last maximized / almost maximized it

    private var restoreMinimizeArmedWindowIDs = Set<CGWindowID>()

    func armRestoreMinimize(windowID: CGWindowID) {
        restoreMinimizeArmedWindowIDs.insert(windowID)
    }

    func resetRestoreMinimize(windowID: CGWindowID) {
        restoreMinimizeArmedWindowIDs.remove(windowID)
    }

    func consumeRestoreMinimize(windowID: CGWindowID, currentFrame: CGRect, restoredFrame: CGRect) -> Bool {
        guard restoreMinimizeArmedWindowIDs.contains(windowID), currentFrame == restoredFrame else {
            return false
        }
        restoreMinimizeArmedWindowIDs.remove(windowID)
        return true
    }
    
}
