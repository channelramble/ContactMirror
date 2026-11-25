#import "ObjCSupport.h"

NSError * _Nullable CMCatchException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: exception.name;
        return [NSError errorWithDomain:@"ContactMirror.ObjCException"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
}
