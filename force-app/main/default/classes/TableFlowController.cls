public with sharing class TableFlowController {
    public class AppException extends Exception {}
    public class LineInput { public Id productId; public Integer quantity; }
    public class TicketInput {
        public String token; public String service; public String tableNo;
        public String note; public Decimal discount; public Decimal tax;
        public List<LineInput> lines;
    }
    private static void require(Boolean condition, String message) {
        if (!condition) throw new AppException(message);
    }
    private static String clean(String value, Integer size) {
        return value == null ? '' : value.trim().left(size);
    }
    private static Id bookId() {
        if (Test.isRunningTest()) return Test.getStandardPricebookId();
        return [SELECT Id FROM Pricebook2 WHERE IsStandard = true WITH USER_MODE LIMIT 1].Id;
    }
    @RemoteAction
    public static String invoke(String action, String payload) {
        Savepoint sp = Database.setSavepoint();
        try {
            Map<String,Object> data = String.isBlank(payload) ? new Map<String,Object>() :
                (Map<String,Object>)JSON.deserializeUntyped(payload);
            if (action == 'seed') seedMenu();
            else if (action == 'create') createTicket(payload);
            else if (action == 'status') changeStatus(data);
            else if (action == 'menu') saveMenu(data);
            else require(action == 'load', 'Unknown operation.');
            return JSON.serialize(new Map<String,Object>{'ok'=>true, 'data'=>snapshot()});
        } catch (Exception ex) {
            Database.rollback(sp);
            return JSON.serialize(new Map<String,Object>{'ok'=>false, 'error'=>ex.getMessage()});
        }
    }
    private static Map<String,Object> snapshot() {
        Id pb = bookId();
        List<PricebookEntry> menu = [SELECT Id, Product2Id, UnitPrice, Product2.Name,
            Product2.ProductCode, Product2.Description, Product2.IsActive
            FROM PricebookEntry WHERE Pricebook2Id = :pb AND Product2.ProductCode LIKE 'TF-%'
            WITH USER_MODE ORDER BY Product2.Name LIMIT 200];
        List<Order> tickets = [SELECT Id, Name, OrderNumber, EffectiveDate, CreatedDate, Description,
            TotalAmount, (SELECT Id, Quantity, UnitPrice, TotalPrice, PricebookEntry.Product2.Name
            FROM OrderItems) FROM Order WHERE Name LIKE 'TF-%'
            WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 200];
        return new Map<String,Object>{'menu'=>menu, 'tickets'=>tickets,
            'user'=>UserInfo.getName(), 'today'=>String.valueOf(Date.today())};
    }
    private static void seedMenu() {
        require([SELECT COUNT() FROM Product2 WHERE ProductCode LIKE 'TF-%' WITH USER_MODE] == 0,
            'Menu already exists. Add dishes using Menu Manager.');
        Id pb = bookId();
        Database.update(new Pricebook2(Id=pb, IsActive=true), AccessLevel.USER_MODE);
        List<String> names = new List<String>{'Paneer Tikka','Crispy Corn','Veg Biryani','Butter Chicken',
            'Dal Makhani','Butter Naan','Masala Dosa','Margherita Pizza','Fresh Lime Soda','Mango Lassi','Gulab Jamun','Brownie'};
        List<String> categories = new List<String>{'Starters','Starters','Mains','Mains','Mains','Breads','Mains','Mains','Drinks','Drinks','Desserts','Desserts'};
        List<Decimal> prices = new List<Decimal>{240,180,220,320,230,55,140,280,80,120,90,150};
        List<Product2> dishes = new List<Product2>();
        for (Integer i=0;i<names.size();i++) dishes.add(new Product2(Name=names[i],
            ProductCode='TF-DEMO-'+i, Description=categories[i], IsActive=true));
        Database.insert(dishes, AccessLevel.USER_MODE);
        List<PricebookEntry> entries = new List<PricebookEntry>();
        for (Integer i=0;i<dishes.size();i++) entries.add(new PricebookEntry(
            Pricebook2Id=pb, Product2Id=dishes[i].Id, UnitPrice=prices[i], IsActive=true));
        Database.insert(entries, AccessLevel.USER_MODE);
    }
    private static void createTicket(String payload) {
        TicketInput input = (TicketInput)JSON.deserialize(payload, TicketInput.class);
        require(input != null && input.lines != null && !input.lines.isEmpty() && input.lines.size()<=50,
            'Add between 1 and 50 dishes.');
        require(!String.isBlank(input.token) && input.token.length()<=60, 'Missing order reference.');
        String ticketName = 'TF-'+input.token;
        if ([SELECT COUNT() FROM Order WHERE Name=:ticketName WITH USER_MODE] > 0) return;
        require(new Set<String>{'Dine-in','Takeaway','Delivery'}.contains(input.service), 'Invalid order type.');
        require(input.service!='Dine-in' || !String.isBlank(input.tableNo), 'Choose a table.');
        Decimal discount = input.discount == null ? 0 : input.discount;
        Decimal tax = input.tax == null ? 0 : input.tax;
        require(discount>=0 && discount<=100 && tax>=0 && tax<=30, 'Invalid discount or tax percentage.');
        Map<Id,Integer> quantities = new Map<Id,Integer>();
        for (LineInput line : input.lines) {
            require(line.productId!=null && line.quantity!=null && line.quantity>0 && line.quantity<=99,
                'Each quantity must be between 1 and 99.');
            Integer amount = (quantities.containsKey(line.productId) ? quantities.get(line.productId) : 0)+line.quantity;
            require(amount<=99,'Maximum 99 of each dish.');
            quantities.put(line.productId,amount);
        }
        Id pb = bookId();
        Set<Id> ids=quantities.keySet();
        List<PricebookEntry> entries=[SELECT Id, Product2Id, UnitPrice FROM PricebookEntry
            WHERE Pricebook2Id=:pb AND Product2Id IN :ids AND IsActive=true AND Product2.IsActive=true
            AND Product2.ProductCode LIKE 'TF-%' WITH USER_MODE];
        require(entries.size()==ids.size(),'A dish is unavailable. Refresh the menu.');
        List<Account> accounts=[SELECT Id FROM Account WHERE Name='TableFlow Restaurant Counter' WITH USER_MODE LIMIT 1];
        Account counter;
        if (accounts.isEmpty()) {
            counter=new Account(Name='TableFlow Restaurant Counter', Description='TableFlow demo restaurant orders');
            Database.insert(counter,AccessLevel.USER_MODE);
        } else counter=accounts[0];
        Decimal subtotal=0;
        for(PricebookEntry entry:entries) subtotal+=entry.UnitPrice*quantities.get(entry.Product2Id);
        Decimal discountAmount=(subtotal*discount/100).setScale(2);
        Decimal taxAmount=((subtotal-discountAmount)*tax/100).setScale(2);
        Map<String,Object> meta=new Map<String,Object>{
            'service'=>input.service,'tableNo'=>clean(input.tableNo,20),'note'=>clean(input.note,400),
            'stage'=>'New','payment'=>'Unpaid','method'=>'','discount'=>discount,'tax'=>tax,
            'subtotal'=>subtotal,'discountAmount'=>discountAmount,'taxAmount'=>taxAmount,
            'grandTotal'=>subtotal-discountAmount+taxAmount};
        Order ticket=new Order(Name=ticketName,AccountId=counter.Id,EffectiveDate=Date.today(),
            Status='Draft',Pricebook2Id=pb,Description=JSON.serialize(meta));
        Database.insert(ticket,AccessLevel.USER_MODE);
        List<OrderItem> lines=new List<OrderItem>();
        for(PricebookEntry entry:entries) lines.add(new OrderItem(OrderId=ticket.Id,
            PricebookEntryId=entry.Id,Quantity=quantities.get(entry.Product2Id),UnitPrice=entry.UnitPrice));
        Database.insert(lines,AccessLevel.USER_MODE);
    }
    private static void changeStatus(Map<String,Object> data) {
        Id recordId=(Id)String.valueOf(data.get('id'));
        Order ticket=[SELECT Id,Name,Description FROM Order WHERE Id=:recordId WITH USER_MODE LIMIT 1 FOR UPDATE];
        require(ticket.Name!=null && ticket.Name.startsWith('TF-'),'Not a TableFlow order.');
        Map<String,Object> meta=(Map<String,Object>)JSON.deserializeUntyped(ticket.Description);
        String stage=(String)data.get('stage');
        if (stage != null) {
            String current=(String)meta.get('stage');
            Map<String,String> nextStage=new Map<String,String>{'New'=>'Preparing','Preparing'=>'Ready','Ready'=>'Served'};
            require(nextStage.get(current)==stage,'Refresh: this order has already changed.');
            meta.put('stage',stage);
        }
        String method=(String)data.get('method');
        if (method != null) {
            require(new Set<String>{'Cash','Card','UPI'}.contains(method),'Choose a payment method.');
            require(meta.get('payment')!='Paid','Payment already recorded.');
            meta.put('payment','Paid'); meta.put('method',method);
        }
        ticket.Description=JSON.serialize(meta);
        Database.update(ticket,AccessLevel.USER_MODE);
    }
    private static void saveMenu(Map<String,Object> data) {
        String name=clean((String)data.get('name'),80);
        String category=clean((String)data.get('category'),40);
        Decimal price=Decimal.valueOf(String.valueOf(data.get('price')));
        require(!String.isBlank(name) && !String.isBlank(category) && price>0 && price<100000,
            'Enter a dish name, category and positive price below 100000.');
        Id pb=bookId();
        String recordId=(String)data.get('id');
        Product2 dish;
        if (String.isBlank(recordId)) dish=new Product2(ProductCode='TF-'+String.valueOf(DateTime.now().getTime()));
        else {
            dish=[SELECT Id,ProductCode FROM Product2 WHERE Id=:recordId WITH USER_MODE LIMIT 1];
            require(dish.ProductCode!=null && dish.ProductCode.startsWith('TF-'),'Not a TableFlow dish.');
        }
        dish.Name=name; dish.Description=category; dish.IsActive=(Boolean)data.get('active');
        if(dish.Id==null) Database.insert(dish,AccessLevel.USER_MODE);
        else Database.update(dish,AccessLevel.USER_MODE);
        List<PricebookEntry> entries=[SELECT Id FROM PricebookEntry WHERE Pricebook2Id=:pb AND Product2Id=:dish.Id WITH USER_MODE LIMIT 1];
        PricebookEntry entry=entries.isEmpty() ? new PricebookEntry(Pricebook2Id=pb,Product2Id=dish.Id) : entries[0];
        entry.UnitPrice=price; entry.IsActive=true;
        if(entry.Id==null) Database.insert(entry,AccessLevel.USER_MODE);
        else Database.update(entry,AccessLevel.USER_MODE);
    }
}
