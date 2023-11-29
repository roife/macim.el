import Carbon
import EmacsSwiftModule

class MacIM: Module {
    let isGPLCompatible = true
    
    func getIme() -> String {
        let inputSource = TISCopyCurrentKeyboardInputSource().takeUnretainedValue()
        return unsafeBitCast(
          TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID),
          to: NSString.self
        ) as String
    }
    
    func setIme(ime: String) -> Bool {
        let filter = [kTISPropertyInputSourceID!: ime] as NSDictionary
        let inputSources =
            TISCreateInputSourceList(filter, false).takeUnretainedValue()
            as NSArray as! [TISInputSource]
        guard !inputSources.isEmpty else {
          return false
        }
        let inputSource = inputSources[0]
        TISSelectInputSource(inputSource)
        return true
    }
    
    func Init(_ env: Environment) throws {
        try env.defun("macim-get",
                      with: "Get name of current input source.",
                      function: self.getIme)
        
        try env.defun("macim-set",
                      with: "Set current input source to ARG1",
                      function: self.setIme(ime:))
    }
}

func createModule() -> Module {
    MacIM()
}
