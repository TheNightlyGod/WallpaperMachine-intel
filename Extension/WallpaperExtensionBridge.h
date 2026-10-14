#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <bsm/libbsm.h>
#import <objc/runtime.h>
#include "SceneWallpaperBindings.h"

// Private macOS wallpaper hosting ABI, resolved/checked before use.
// Protocol reference: kageroumado/phosphene, revision 8b5bd57c1450eda74cf2ec6ceaae2e586cfdfcd6.
@interface CAContext : NSObject
@property(nonatomic, readonly) unsigned int contextId;
@property(nonatomic, retain) CALayer *layer;
- (void)invalidate;
@end

@interface NSXPCConnection (WallpaperCallerIdentity)
@property(nonatomic, readonly) audit_token_t auditToken;
@end

// The selector list was read from the system's own
// WallpaperExtensionKit.WallpaperExtensionXPCProtocol (macOS 27.0, 21 selectors), and the
// extension compares the two at runtime and logs any drift (WallpaperRuntime.verifyXPCProtocol).
// Every selector the system declares is declared here with the same argument and reply shapes:
// a selector missing from the exported interface invalidates the agent's connection, and a
// declared selector the exported object lacks raises an uncaught exception in the extension.
@protocol WallpaperExtensionXPCProtocol <NSObject>
- (void)acquireWithId:(id)identifier request:(id)request reply:(void (^)(id, NSError *))reply;
- (void)updateWithId:(id)identifier request:(id)request reply:(void (^)(NSError *))reply;
- (void)invalidateWithId:(id)identifier reply:(void (^)(NSError *))reply;
- (void)snapshotWithId:(id)identifier reply:(void (^)(id, NSError *))reply;
- (void)provideSettingsViewModelsWithContentTypes:(id)types reply:(void (^)(id, NSError *))reply;
// macOS 27 declares an NSNumber reply here; a reply of another type invalidates the connection.
- (void)isChoiceDownloadedWith:(id)choiceID reply:(void (^)(id, NSError *))reply;
- (void)selectedChoicesDidChangeFor:(id)identifier reply:(void (^)(NSError *))reply;
- (void)migrateSelectedChoiceFor:(id)choiceID reply:(void (^)(id, NSError *))reply;
- (void)addChoiceRequestWithChoiceRequest:(id)choiceRequest onBehalfOfProcess:(id)process reply:(void (^)(id, NSError *))reply;
- (void)canSkipShuffledContentWithId:(id)identifier reply:(void (^)(BOOL, NSError *))reply;
- (void)skipShuffledContentWithId:(id)identifier reply:(void (^)(NSError *))reply;
- (void)removeChoiceRequestWithChoiceRequest:(id)choiceRequest reply:(void (^)(NSError *))reply;
- (NSProgress *)downloadWithChoiceID:(id)choiceID reply:(void (^)(NSError *))reply;
- (void)cancelDownloadFor:(id)choiceID reply:(void (^)(NSError *))reply;
- (void)pauseDownloadFor:(id)choiceID reply:(void (^)(NSError *))reply;
- (void)resumeDownloadFor:(id)choiceID reply:(void (^)(NSError *))reply;
- (void)removeDownloadFor:(id)choiceID reply:(void (^)(NSError *))reply;
- (void)invokeContextMenuActionWithMenuItemID:(NSString *)itemID groupItemID:(NSString *)groupItemID reply:(void (^)(NSError *))reply;
- (void)migrateFrom:(id)from to:(id)to reply:(void (^)(NSError *))reply;
- (void)handleDebugRequestFor:(id)request reply:(void (^)(id, NSError *))reply;
- (void)handleNotificationWithNamed:(NSString *)name reply:(void (^)(NSError *))reply;
@end
