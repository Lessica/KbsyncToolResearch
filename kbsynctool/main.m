#import <stdio.h>
#import <notify.h>

#import <Foundation/Foundation.h>
#import <rocketbootstrap/rocketbootstrap.h>

#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerErrorResponse.h"

#import "kern_memorystatus.h"


static id RocketGetJSONResponse(NSString *urlString, NSString *syncType)
{
    @autoreleasepool
    {
        CFMessagePortRef remotePort = rocketbootstrap_cfmessageportcreateremote(NULL, CFSTR("com.darwindev.itunesstored.kbsync.port"));
        if (!remotePort) {
            fprintf(stderr, "no remote port found\n");
            return [NSDictionary dictionary];
        }

        CFDataRef data = (CFDataRef)CFBridgingRetain([NSPropertyListSerialization dataWithPropertyList:@{
            @"url": urlString, @"kbsyncType": syncType, @"sbsyncType": syncType} format:NSPropertyListBinaryFormat_v1_0 options:kNilOptions error:nil]);
        CFDataRef returnData = NULL;
        SInt32 status =
            CFMessagePortSendRequest(
                remotePort,
                0x1111,
                data,
                3.0,
                3.0,
                kCFRunLoopDefaultMode,
                &returnData
            );
        
        CFRelease(data);

        if (status != kCFMessagePortSuccess) {
            fprintf(stderr, "CFMessagePortSendRequest %d\n", status);
            
            CFMessagePortInvalidate(remotePort);
            CFRelease(remotePort);
            return [NSDictionary dictionary];
        }

        CFMessagePortInvalidate(remotePort);
        CFRelease(remotePort);
        
        return [NSPropertyListSerialization propertyListWithData:CFBridgingRelease(returnData) options:kNilOptions format:nil error:nil];
    }
}


int main(int argc, char *argv[], char *envp[]) {
    @autoreleasepool {
        if (argc != 2 && argc != 3) {
            fprintf(stderr, "usage: %s [url] [-p port]\n", argv[0]);
            return 1;
        }

        if (argc == 2) {

            // one-time execute

            NSString *urlString = [NSString stringWithUTF8String:argv[1]];
            id returnObj = RocketGetJSONResponse(urlString, @"base64");
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:returnObj options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys) error:nil];
            NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];

            if (jsonString) {
                printf("%s\n", [jsonString UTF8String]);
            }

            return jsonString != nil ? 0 : 1;
        } else {

            // launch server

            /* increase memory usage */
            int rc;
            
            memorystatus_priority_properties_t props = {0, JETSAM_PRIORITY_CRITICAL};
            rc = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, getpid(), 0, &props, sizeof(props));
            if (rc < 0) { perror ("memorystatus_control"); exit(rc); }
            
            rc = memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK, getpid(), -1, NULL, 0);
            if (rc < 0) { perror ("memorystatus_control"); exit(rc); }
            
            rc = memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED, getpid(), 0, NULL, 0);
            if (rc < 0) { perror ("memorystatus_control"); exit(rc); }
            
            rc = memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_FREEZABLE, getpid(), 0, NULL, 0);
            if (rc < 0) { perror ("memorystatus_control"); exit(rc); }

            NSInteger port = [[NSString stringWithUTF8String:argv[2]] integerValue];
            if (port <= 0 || port > 65535) {
                fprintf(stderr, "invalid server port\n");
                return 1;
            }

            GCDWebServer *webServer = [[GCDWebServer alloc] init];
            GCDWebServerAsyncProcessBlock webCallback = ^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
                @autoreleasepool {
                    NSString *urlString = [request query][@"url"];
                    if (!urlString) {
                        completionBlock([GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest message:@"invalid url"]);
                        return;
                    }

                    id returnObj = RocketGetJSONResponse(urlString, @"hex");
                    if (!returnObj) {
                        completionBlock([GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError message:@"invalid url"]);
                        return;
                    }

                    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:returnObj options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys) error:nil];
                    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];

                    if (jsonString) {
                        NSLog(@"%@", jsonString);
                    }

                    completionBlock([GCDWebServerDataResponse responseWithData:jsonData contentType:@"application/json"]);
                }
            };

            [webServer addDefaultHandlerForMethod:@"GET"
                                    requestClass:[GCDWebServerRequest class]
                                asyncProcessBlock:webCallback];
            [webServer addDefaultHandlerForMethod:@"POST"
                                    requestClass:[GCDWebServerRequest class]
                                asyncProcessBlock:webCallback];
            
            [webServer addHandlerForMethod:@"POST" path:@"/notify_post" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse * _Nullable(GCDWebServerDataRequest * _Nonnull request) {
                @autoreleasepool {
                    NSString *name = request.text;
                    if (!name) {
                        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest message:@"invalid notification name"];
                    }
                    NSArray <NSString *> *availableNames = @[
                        @"com.darwindev.kbsync.app-usage.flush",
                        @"com.darwindev.kbsync.app-usage.reset",
                    ];
                    if (![availableNames containsObject:name]) {
                        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest message:@"invalid notification name"];
                    }
                    notify_post([name UTF8String]);
                    return [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_OK];
                }
            }];

            [webServer startWithPort:port bonjourName:nil];
            NSLog(@"Using -s %@ with NyaMisty/ipatool-py...", webServer.serverURL);

            CFRunLoopRun();
            return 0;
        }
    }
}
