//
//  PurchasesManager.m
//  Baker
//
//  ==========================================================================================
//
//  Copyright (c) 2010-2012, Davide Casali, Marco Colombo, Alessandro Morandi
//  All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without modification, are
//  permitted provided that the following conditions are met:
//
//  Redistributions of source code must retain the above copyright notice, this list of
//  conditions and the following disclaimer.
//  Redistributions in binary form must reproduce the above copyright notice, this list of
//  conditions and the following disclaimer in the documentation and/or other materials
//  provided with the distribution.
//  Neither the name of the Baker Framework nor the names of its contributors may be used to
//  endorse or promote products derived from this software without specific prior written
//  permission.
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
//  EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
//  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT
//  SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
//  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
//  PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
//  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
//  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#import "PurchasesManager.h"

#import "JSONKit.h"
#import "NSData+Base64.h"
#import "NSMutableURLRequest+WebServiceClient.h"

#ifdef BAKER_NEWSSTAND
@implementation PurchasesManager

@synthesize products;

-(id)init {
    self = [super init];

    if (self) {
        self.products = [[NSMutableDictionary alloc] init];

        _purchases = [[NSMutableDictionary alloc] init];

        _numberFormatter = [[NSNumberFormatter alloc] init];
        [_numberFormatter setFormatterBehavior:NSNumberFormatterBehavior10_4];
        [_numberFormatter setNumberStyle:NSNumberFormatterCurrencyStyle];
    }

    return self;
}

#pragma mark - Singleton

+ (PurchasesManager *)sharedInstance {
    static dispatch_once_t once;
    static PurchasesManager *sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

#pragma mark - Purchased flag

- (BOOL)isMarkedAsPurchased:(NSString *)productID {
    return [[NSUserDefaults standardUserDefaults] boolForKey:productID];
}

- (void)markAsPurchased:(NSString *)productID {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:productID];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - Prices

- (void)retrievePricesFor:(NSSet *)productIDs {
    if ([productIDs count] > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void) {
            SKProductsRequest *productsRequest = [[SKProductsRequest alloc] initWithProductIdentifiers:productIDs];
            productsRequest.delegate = self;
            [productsRequest start];
        });
    }
}

- (void)retrievePriceFor:(NSString *)productID {
    NSSet *productIDs = [NSSet setWithObject:productID];
    [self retrievePricesFor:productIDs];
}

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response {
    NSLog(@"############ REQUEST RECEIVED RESPONSE %@", response.products);
    
    for (NSString *productID in response.invalidProductIdentifiers) {
        NSLog(@"Invalid product identifier: %@", productID);
    }
    
    NSMutableSet *ids = [NSMutableSet setWithCapacity:response.products.count];
    for (SKProduct *skProduct in response.products) {
        [self.products setObject:skProduct forKey:skProduct.productIdentifier];
        [ids addObject:skProduct.productIdentifier];
    }
    
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:ids forKey:@"ids"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"notification_products_retrieved" object:self userInfo:userInfo];

    [request release];
}

- (void)request:(SKRequest *)request didFailWithError:(NSError *)error {
    NSLog(@"App Store request failure: %@", error);

    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:error forKey:@"error"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"notification_products_request_failed" object:self userInfo:userInfo];

    [request release];
}

- (NSString *)priceFor:(NSString *)productID {
    SKProduct *product = [products objectForKey:productID];
    if (product) {
        [_numberFormatter setLocale:product.priceLocale];
        return [_numberFormatter stringFromNumber:product.price];
    }
    return nil;
}

#pragma mark - Purchases

- (BOOL)purchase:(NSString *)productID {
    SKProduct *product = [self productFor:productID];
    if (product) {
        SKPayment *payment = [SKPayment paymentWithProduct:product];
        [[SKPaymentQueue defaultQueue] addPayment:payment];

        return YES;
    } else {
        NSLog(@"Trying to buy unavailable product %@", productID);

        return NO;
    }
}

- (void)finishTransaction:(SKPaymentTransaction *)transaction {
    [self recordTransaction:transaction];
    [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
}

-(void)recordTransaction:(SKPaymentTransaction *)transaction {
    [[NSUserDefaults standardUserDefaults] setObject:transaction.transactionIdentifier forKey:@"receipt"];
    
    if ([PURCHASE_CONFIRMATION_URL length] > 0) {
        NSString *receiptData = [transaction.transactionReceipt base64EncodedString];
        NSDictionary *jsonDict = [NSDictionary dictionaryWithObjectsAndKeys:
                                  receiptData, @"receipt-data",
                                  nil];
        NSError *error = nil;
        NSData *jsonData = [jsonDict JSONDataWithOptions:JKSerializeOptionNone error:&error];

        if (error) {
            NSLog(@"Error generating receipt JSON: %@", error);
        } else {
            NSURL *requestURL = [NSURL URLWithString:PURCHASE_CONFIRMATION_URL];
            NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:requestURL];
            [req setHTTPMethod:@"POST"];
            [req setHTTPBody:jsonData];
            NSURLConnection *conn = [[NSURLConnection alloc] initWithRequest:req delegate:nil];
            if (conn) {
                NSLog(@"Posting App Store transaction receipt to %@", PURCHASE_CONFIRMATION_URL);
            } else {
                NSLog(@"Cannot connect to %@", PURCHASE_CONFIRMATION_URL);
            }
            [conn release];
            [req release];
        }
    }
}

- (void)retrievePurchasesFor:(NSSet *)productIDs {
    NSError *error;
    NSURLResponse *response = nil;

    NSString *jsonIDs = [[productIDs allObjects] JSONStringWithOptions:JKSerializeOptionNone error:&error];
    NSDictionary *params = [NSDictionary dictionaryWithObjectsAndKeys:
                            @"com.bakerframework.Baker", @"app_id",
                            @"asdfgh123456", @"user_id",
                            jsonIDs, @"issues",
                            nil];

    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:@"http://localhost/baker/index.php"] cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:REQUEST_TIMEOUT];
    [request setHTTPMethod:@"POST"];
    [request setFormPostParameters:params];
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    NSString *jsonResponse = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"DATA %@", jsonResponse);

    NSDictionary *purchasesResponse = [jsonResponse objectFromJSONString];
    [purchasesResponse enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        [_purchases setObject:obj forKey:key];
    }];
}

- (BOOL)isPurchased:(NSString *)productID {
    id purchased = [_purchases objectForKey:productID];
    if (purchased) {
        return [purchased boolValue];
    } else {
        return [self isMarkedAsPurchased:productID];
    }
}

#pragma mark - Payment queue

- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray *)transactions {
    NSLog(@"############ UPDATED TRANSACTIONS %@", transactions);
    
    for(SKPaymentTransaction *transaction in transactions) {
        switch (transaction.transactionState) {
            case SKPaymentTransactionStatePurchasing:
                // Nothing to do at the moment
                break;
            case SKPaymentTransactionStatePurchased:
                [self completeTransaction:transaction];
                break;
            case SKPaymentTransactionStateFailed:
                [self failedTransaction:transaction];
                break;
            case SKPaymentTransactionStateRestored:
                [self restoreTransaction:transaction];
                break;
            default:
                break;
        }
    }
}

- (void)completeTransaction:(SKPaymentTransaction *)transaction {
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:transaction forKey:@"transaction"];
    NSString *productId = transaction.payment.productIdentifier;

    if ([productId isEqualToString:PRODUCT_ID_FREE_SUBSCRIPTION] || [SUBSCRIPTION_PRODUCT_IDS containsObject:productId]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"notification_subscription_purchased" object:self userInfo:userInfo];
    } else {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"notification_issue_purchased" object:self userInfo:userInfo];
    }
}

- (void)restoreTransaction:(SKPaymentTransaction *)transaction {
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:transaction forKey:@"transaction"];
    NSString *productId = transaction.payment.productIdentifier;

    if ([productId isEqualToString:PRODUCT_ID_FREE_SUBSCRIPTION] || [SUBSCRIPTION_PRODUCT_IDS containsObject:productId]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"notification_subscription_restored" object:self userInfo:userInfo];
    } else {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"notification_issue_restored" object:self userInfo:userInfo];
    }
}

-(void)failedTransaction:(SKPaymentTransaction *)transaction {
    NSLog(@"Payment transaction failure: %@", transaction.error);

    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:transaction forKey:@"transaction"];
    NSString *productId = transaction.payment.productIdentifier;

    if ([productId isEqualToString:PRODUCT_ID_FREE_SUBSCRIPTION] || [SUBSCRIPTION_PRODUCT_IDS containsObject:productId]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"notification_subscription_failed" object:self userInfo:userInfo];
    } else {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"notification_issue_purchase_failed" object:self userInfo:userInfo];
    }

    [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
}

- (void)restore {
    [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
}

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"notification_restore_finished" object:self userInfo:nil];
}

- (void)paymentQueue:(SKPaymentQueue *)queue restoreCompletedTransactionsFailedWithError:(NSError *)error {
    NSLog(@"Transaction restore failure: %@", error);

    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:error forKey:@"error"];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"notification_restore_failed" object:self userInfo:userInfo];
}

#pragma mark - Products

- (SKProduct *)productFor:(NSString *)productID {
    return [self.products objectForKey:productID];
}

#pragma mark - Subscriptions

- (BOOL)hasSubscriptions {
    return [PRODUCT_ID_FREE_SUBSCRIPTION length] > 0;
}

#pragma mark - Memory management

-(void)dealloc {
    [products release];
    [_numberFormatter release];
    [_purchases release];

    [super dealloc];
}

@end
#endif
