#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Runs `block`, converting any Objective-C exception into a returned NSError.
NSError * _Nullable CMCatchException(void (NS_NOESCAPE ^block)(void));
NS_ASSUME_NONNULL_END
